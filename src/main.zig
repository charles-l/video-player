const std = @import("std");
const c = @cImport({
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavutil/imgutils.h");
    @cInclude("libswscale/swscale.h");
});

const rl = @cImport({
    @cInclude("raylib.h");
});

const AV_EOF = std.mem.readPackedInt(u32, "EOF ", 0, .Little);
const max_audio_frame_size = 192000;
const audio_thread_buffer_size = max_audio_frame_size * 3 / 2;
const max_packet_frames = 3840;

var audio_codec_ctx: ?*c.AVCodecContext = null;
var audio_batch_queue = std.atomic.Queue([max_packet_frames]u16).init();

export fn audio_callback(buffer: ?*anyopaque, frames: u32) void {
    var buf = @ptrCast([*]u16, @alignCast(@alignOf(u16), buffer))[0 .. frames * @intCast(u32, audio_codec_ctx.?.channels)];

    @memset(@ptrCast([*]u8, buf), 0, buf.len * @sizeOf(u16));
    if (audio_batch_queue.get()) |batch| {
        std.mem.copy(u16, buf, batch.data[0..@min(buf.len, batch.data.len)]);
    }
}

pub fn main() !void {
    rl.InitWindow(800, 600, "vid");
    defer rl.CloseWindow();

    rl.InitAudioDevice();
    defer rl.CloseAudioDevice();

    rl.SetAudioStreamBufferSizeDefault(3840 * 2);

    var format_ctx: ?*c.AVFormatContext = null;
    if (c.avformat_open_input(&format_ctx, "/home/nc/Downloads/Mice and cheese - Animation-kMYokm13GyM.mkv", null, null) < 0) {
        return error.CouldNotOpenFile;
    }
    defer c.avformat_close_input(&format_ctx);

    if (c.avformat_find_stream_info(format_ctx, null) < 0) {
        return error.CouldNotFindStreamInfo;
    }

    c.av_dump_format(format_ctx, 0, "anim.mkv", 0);

    //// audio codec setup ////
    const audio_stream_i = lbl: {
        var i: usize = 0;
        while (i < format_ctx.?.nb_streams) : (i += 1) {
            if (format_ctx.?.streams[i].*.codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO) {
                break :lbl i;
            }
        }
        return error.FailedToFindAudioStream;
    };

    var audio_codec = c.avcodec_find_decoder(format_ctx.?.streams[audio_stream_i].*.codecpar.*.codec_id);
    if (audio_codec == null) {
        return error.CouldNotFindCodec;
    }

    audio_codec_ctx = c.avcodec_alloc_context3(audio_codec);
    if (c.avcodec_parameters_to_context(audio_codec_ctx, format_ctx.?.streams[audio_stream_i].*.codecpar) < 0) {
        return error.FailedToParseCodec;
    }
    defer _ = c.avcodec_close(audio_codec_ctx);

    if (c.avcodec_open2(audio_codec_ctx, audio_codec, null) < 0) {
        return error.CouldNotOpenCodec;
    }

    var audio_stream = rl.LoadAudioStream(@intCast(u32, audio_codec_ctx.?.sample_rate), 16, @intCast(u32, audio_codec_ctx.?.channels));
    rl.SetAudioStreamCallback(audio_stream, audio_callback);
    rl.PlayAudioStream(audio_stream);

    //// video codec setup ////
    const video_stream_i = lbl: {
        var i: usize = 0;
        while (i < format_ctx.?.nb_streams) : (i += 1) {
            if (format_ctx.?.streams[i].*.codecpar.*.codec_type == c.AVMEDIA_TYPE_VIDEO) {
                break :lbl i;
            }
        }
        return error.FailedToFindVideoStream;
    };

    var codec = c.avcodec_find_decoder(format_ctx.?.streams[video_stream_i].*.codecpar.*.codec_id);
    if (codec == null) {
        return error.CouldNotFindCodec;
    }

    // XXX: the notes said this should be copied from the original source, but
    // I guess this is using the source directly?
    const codec_ctx = c.avcodec_alloc_context3(codec);
    if (c.avcodec_parameters_to_context(codec_ctx, format_ctx.?.streams[video_stream_i].*.codecpar) < 0) {
        return error.FailedToParseCodec;
    }
    defer _ = c.avcodec_close(codec_ctx);

    if (c.avcodec_open2(codec_ctx, codec, null) < 0) {
        return error.CouldNotOpenCodec;
    }

    var frame = c.av_frame_alloc();
    if (frame == null) {
        return error.CouldNotAllocFrame;
    }
    defer c.av_frame_free(&frame);
    defer c.av_free(@ptrCast(*anyopaque, frame));

    var frame_rgb = c.av_frame_alloc();
    if (frame_rgb == null) {
        return error.CouldNotAllocFrame;
    }
    defer c.av_frame_free(&frame_rgb);
    defer c.av_free(@ptrCast(*anyopaque, frame_rgb));

    const num_bytes = @intCast(usize, c.av_image_get_buffer_size(c.AV_PIX_FMT_RGB24, codec_ctx.*.width, codec_ctx.*.height, 32));
    const buffer = @ptrCast([*]u8, c.av_malloc(num_bytes * @sizeOf(u8)))[0 .. num_bytes * @sizeOf(u8)];
    defer c.av_free(@ptrCast(*anyopaque, buffer));

    if (c.av_image_fill_arrays(
        &frame_rgb.*.data,
        &frame_rgb.*.linesize,
        @ptrCast([*c]const u8, buffer),
        c.AV_PIX_FMT_RGB24,
        codec_ctx.*.width,
        codec_ctx.*.height,
        32,
    ) < 0) {
        return error.FailedToImageFillArray;
    }

    const packet = c.av_packet_alloc();
    if (packet == null) {
        return error.CouldNotAllocPacket;
    }

    const sws_ctx = c.sws_getContext(
        codec_ctx.*.width,
        codec_ctx.*.height,
        codec_ctx.*.pix_fmt,
        codec_ctx.*.width,
        codec_ctx.*.height,
        c.AV_PIX_FMT_RGB24,
        c.SWS_BILINEAR,
        null,
        null,
        null,
    );

    var frame_i: u32 = 0;
    while (c.av_read_frame(format_ctx, packet) >= 0 and !rl.WindowShouldClose()) : (frame_i += 1) {
        if (packet.*.stream_index == video_stream_i) {
            if (c.avcodec_send_packet(codec_ctx, packet) < 0) {
                return error.ErrorDecodingPacket;
            }

            while (true) {
                rl.BeginDrawing();

                const r = c.avcodec_receive_frame(codec_ctx, frame);
                if (r == c.AVERROR(c.EAGAIN) or r == AV_EOF) {
                    break;
                } else if (r < 0) {
                    return error.ErrorDecodingPacket;
                }

                if (c.sws_scale(
                    sws_ctx,
                    &frame.*.data,
                    &frame.*.linesize,
                    0,
                    codec_ctx.*.height,
                    &frame_rgb.*.data,
                    &frame_rgb.*.linesize,
                ) < 0) {
                    return error.FailedToRescale;
                }

                const fps = c.av_q2d(format_ctx.?.streams[video_stream_i].*.r_frame_rate);
                rl.WaitTime(1.0 / fps);

                const img = rl.Image{
                    .data = @ptrCast(*anyopaque, frame_rgb.*.data[0]),
                    .width = codec_ctx.*.width,
                    .height = codec_ctx.*.height,
                    .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8,
                    .mipmaps = 1,
                };

                const tex = rl.LoadTextureFromImage(img);
                defer rl.UnloadTexture(tex);
                rl.DrawTexture(tex, 0, 0, rl.WHITE);

                rl.EndDrawing();
            }
            c.av_packet_unref(packet);
        } else if (packet.*.stream_index == audio_stream_i) {
            if (c.avcodec_send_packet(audio_codec_ctx, packet) < 0) {
                return error.ErrorDecodingPacket;
            }

            var batch = [_]u16{0} ** max_packet_frames;
            var batch_i: usize = 0;
            var i: u32 = 0;
            while (true) : (i += 1) {
                const r = c.avcodec_receive_frame(audio_codec_ctx, frame);
                if (r == c.AVERROR(c.EAGAIN) or r == AV_EOF) {
                    break;
                } else if (r < 0) {
                    return error.ErrorDecodingPacket;
                }
                //std.mem.copy(
                //    u16,
                //    batch[batch_i..],
                //    frame.*.data[0][0..@intCast(usize, frame.*.linesize[0])],
                //);
                batch_i += @intCast(usize, frame.*.linesize[0]);
            }

            var node = @TypeOf(audio_batch_queue).Node{ .data = .{} };
            @memset(@ptrCast([*]u8, &node.data), 0, node.data.len * @sizeOf(u16));
            _ = batch;
            audio_batch_queue.put(&node);

            c.av_packet_unref(packet);
        } else {
            c.av_packet_unref(packet);
        }
    }
}
