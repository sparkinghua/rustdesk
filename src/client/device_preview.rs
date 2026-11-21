use base::message_proto::{video_frame, VideoFrame};
use hbb_common::{bail, log, ResultType};
use scrap::{codec::Decoder, CodecFormat, ImageFormat, ImageRgb};
use std::{fs, net::SocketAddrV4, path::PathBuf};

pub(super) fn endpoint_path(id: &str) -> Option<PathBuf> {
    let address: SocketAddrV4 = id.parse().ok()?;
    let ip = address.ip();
    let [first, second, _, _] = ip.octets();
    if address.port() != 21118 || first != 100 || !(64..=127).contains(&second) {
        return None;
    }
    Some(
        PathBuf::from(std::env::var_os("APPDATA")?)
            .join("RustDesk")
            .join("device-previews")
            .join(format!("{ip}-21118.png")),
    )
}

pub(super) fn keyframe(frame: &VideoFrame) -> Option<VideoFrame> {
    use video_frame::Union::*;
    let packets = match frame.union.as_ref()? {
        Vp8s(v) | Vp9s(v) | Av1s(v) | H264s(v) | H265s(v) => &v.frames,
        _ => return None,
    };
    if packets.iter().any(|packet| packet.key)
        && packets
            .iter()
            .map(|packet| packet.data.len())
            .sum::<usize>()
            <= 8 * 1024 * 1024
    {
        Some(frame.clone())
    } else {
        None
    }
}

// Called only after the normal session decoder has rendered a frame.
pub(super) fn save_async(path: PathBuf, frame: VideoFrame) {
    if let Err(err) = std::thread::Builder::new()
        .name("device-preview".to_owned())
        .spawn(move || {
            if let Err(err) = save(path, frame) {
                log::debug!("Could not save device preview: {err}");
            }
        })
    {
        log::debug!("Could not start device preview worker: {err}");
    }
}

fn save(path: PathBuf, frame: VideoFrame) -> ResultType<()> {
    let Some(packets) = &frame.union else {
        return Ok(());
    };
    // No adapter LUID selects RAM output without changing the session renderer.
    let mut decoder = Decoder::new(CodecFormat::from(&frame), None);
    let mut rgb = ImageRgb::new(ImageFormat::ABGR, 1);
    if !decoder.handle_video_frame(
        packets,
        &mut rgb,
        &mut Default::default(),
        &mut true,
        &mut None,
    )? {
        bail!("Keyframe did not produce a preview image");
    }
    let Some(image) = image::RgbaImage::from_raw(rgb.w as u32, rgb.h as u32, rgb.raw) else {
        bail!("Invalid preview frame dimensions");
    };
    let thumbnail = image::DynamicImage::ImageRgba8(image).thumbnail(640, 360);
    let Some(dir) = path.parent() else {
        return Ok(());
    };
    fs::create_dir_all(dir)?;
    let temporary = dir.join(format!("{}.png", hbb_common::uuid::Uuid::new_v4()));
    let result = (|| -> ResultType<()> {
        thumbnail.save(&temporary)?;
        fs::rename(&temporary, path)?;
        Ok(())
    })();
    if result.is_err() {
        if let Err(err) = fs::remove_file(&temporary) {
            log::debug!("Could not remove temporary device preview: {err}");
        }
    }
    result
}
