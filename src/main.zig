const std = @import("std");
const print = std.debug.print;
const c = @cImport({
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavutil/imgutils.h");
    @cInclude("libavutil/opt.h");
    @cInclude("libswresample/swresample.h");
    @cInclude("libswscale/swscale.h");
});

const rl = @cImport({
    @cInclude("raylib.h");
});

const AV_EOF = std.mem.readPackedInt(u32, "EOF ", 0, .Little);

var audio_codec_ctx: ?*c.AVCodecContext = null;
var audio_batch_queue = std.atomic.Queue(std.ArrayList(i16)).init();

var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
const gpa = general_purpose_allocator.allocator();

var sine_idx: f32 = 0;

export fn audio_callback(buffer: ?*anyopaque, frames: u32) void {
    var buf = @ptrCast([*]i16, @alignCast(@alignOf(i16), buffer))[0 .. frames * 2];
    var frames_filled: usize = 0;

    @memset(@ptrCast([*]u8, buf), 0, buf.len * @sizeOf(i16));
    while (frames_filled < buf.len) {
        if (audio_batch_queue.get()) |batch| {
            if (frames_filled + batch.data.items.len < buf.len) {
                std.mem.copy(i16, buf[frames_filled..], batch.data.items);
                frames_filled += batch.data.items.len;
                batch.data.deinit();
                gpa.destroy(batch);
            } else {
                std.mem.copy(i16, buf[frames_filled..], batch.data.items[0 .. buf.len - frames_filled]);

                var leftover = std.ArrayList(i16).init(gpa);
                leftover.appendSlice(batch.data.items[buf.len - frames_filled ..]) catch @panic("couldn't append");

                batch.data.deinit();

                batch.data = leftover;
                audio_batch_queue.unget(batch);

                frames_filled += buf.len - frames_filled;
            }
        } else {
            print("starved\n", .{});
            break;
        }
    }
}

fn assertNotNull(x: anytype) @TypeOf(x) {
    if (x == null) {
        @panic("expected to be not null");
    }
    return x;
}

// check for an error in ffmpeg return value
fn check(x: anytype, e: anyerror) !@TypeOf(x) {
    if (@TypeOf(x) == c_int) {
        if (x < 0) {
            return e;
        }
    } else {
        if (x == null) {
            return e;
        }
    }
    return x;
}

pub fn main() !void {
    defer std.debug.assert(!general_purpose_allocator.deinit());
    defer {
        // cleanup any leftover data in the queue
        while (audio_batch_queue.get()) |n| {
            n.data.deinit();
            gpa.destroy(n);
        }
    }

    rl.InitWindow(800, 600, "vid");
    defer rl.CloseWindow();

    rl.InitAudioDevice();
    defer rl.CloseAudioDevice();

    var format_ctx: ?*c.AVFormatContext = null;
    _ = try check(c.avformat_open_input(&format_ctx, "/home/nc/Downloads/Mice and cheese - Animation-kMYokm13GyM.mkv", null, null), error.OpeningFile);
    defer c.avformat_close_input(&format_ctx);

    _ = try check(c.avformat_find_stream_info(format_ctx, null), error.FindingStream);

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

    var audio_codec = try check(c.avcodec_find_decoder(format_ctx.?.streams[audio_stream_i].*.codecpar.*.codec_id), error.FindingCodec);

    audio_codec_ctx = c.avcodec_alloc_context3(audio_codec);
    _ = try check(c.avcodec_parameters_to_context(audio_codec_ctx, format_ctx.?.streams[audio_stream_i].*.codecpar), error.CodecSetup);

    defer _ = c.avcodec_close(audio_codec_ctx);
    defer c.avcodec_free_context(&audio_codec_ctx);

    _ = try check(c.avcodec_open2(audio_codec_ctx, audio_codec, null), error.OpeningCodec);

    var audio_stream = rl.LoadAudioStream(@intCast(u32, audio_codec_ctx.?.sample_rate), 16, 2);
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

    var codec = try check(c.avcodec_find_decoder(format_ctx.?.streams[video_stream_i].*.codecpar.*.codec_id), error.FindingCodec);

    // XXX: the notes said this should be copied from the original source, but
    // I guess this is using the source directly?
    var codec_ctx = c.avcodec_alloc_context3(codec);
    _ = try check(c.avcodec_parameters_to_context(codec_ctx, format_ctx.?.streams[video_stream_i].*.codecpar), error.CodecSetup);

    defer _ = c.avcodec_close(codec_ctx);
    defer c.avcodec_free_context(&codec_ctx);

    _ = try check(c.avcodec_open2(codec_ctx, codec, null), error.OpeningCodec);

    var frame = try check(c.av_frame_alloc(), error.AllocFailure);
    defer c.av_frame_free(&frame);

    var frame_rgb = try check(c.av_frame_alloc(), error.AllocFailure);
    defer c.av_frame_free(&frame_rgb);

    const num_bytes = @intCast(usize, c.av_image_get_buffer_size(c.AV_PIX_FMT_RGB24, codec_ctx.*.width, codec_ctx.*.height, 32));
    const buffer = try gpa.alloc(u8, num_bytes);
    defer gpa.free(buffer);

    _ = try check(c.av_image_fill_arrays(
        &frame_rgb.*.data,
        &frame_rgb.*.linesize,
        &buffer[0],
        c.AV_PIX_FMT_RGB24,
        codec_ctx.*.width,
        codec_ctx.*.height,
        32,
    ), error.FailedToImageFillArray);

    var packet: c.AVPacket = undefined;
    c.av_init_packet(&packet);
    packet.data = null;
    packet.size = 0;

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
    defer c.sws_freeContext(sws_ctx);

    var swr_ctx = try check(c.swr_alloc(), error.AllocFailure);
    defer c.swr_free(&swr_ctx);

    _ = try check(c.av_opt_set_chlayout(swr_ctx, "in_chlayout", &audio_codec_ctx.?.ch_layout, 0), error.FailedToSetOption);
    _ = try check(c.av_opt_set_int(swr_ctx, "in_sample_rate", audio_codec_ctx.?.sample_rate, 0), error.FailedToSetOption);
    _ = try check(c.av_opt_set_sample_fmt(swr_ctx, "in_sample_fmt", audio_codec_ctx.?.sample_fmt, 0), error.FailedToSetOption);

    _ = try check(c.av_opt_set_int(swr_ctx, "out_channel_layout", c.AV_CH_LAYOUT_STEREO, 0), error.FailedToSetOption);
    _ = try check(c.av_opt_set_int(swr_ctx, "out_sample_rate", audio_codec_ctx.?.sample_rate, 0), error.FailedToSetOption);
    _ = try check(c.av_opt_set_sample_fmt(swr_ctx, "out_sample_fmt", c.AV_SAMPLE_FMT_S16, 0), error.FailedToSetOption);

    _ = try check(c.swr_init(swr_ctx), error.FailedToInit);

    const img = rl.Image{
        .data = null,
        .width = codec_ctx.*.width,
        .height = codec_ctx.*.height,
        .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8,
        .mipmaps = 1,
    };

    const tex = rl.LoadTextureFromImage(img);
    defer rl.UnloadTexture(tex);

    var frame_i: u32 = 0;
    // FIXME: this av_read_frame call still seems to be leaking a bit of memory somewhere...
    while (c.av_read_frame(format_ctx, &packet) >= 0 and !rl.WindowShouldClose()) : (frame_i += 1) {
        if (packet.stream_index == video_stream_i) {
            _ = try check(c.avcodec_send_packet(codec_ctx, &packet), error.DecodingPacket);

            while (true) {
                rl.BeginDrawing();

                const r = c.avcodec_receive_frame(codec_ctx, frame);
                if (r == c.AVERROR(c.EAGAIN) or r == AV_EOF) {
                    break;
                } else if (r < 0) {
                    return error.ErrorDecodingPacket;
                }

                _ = try check(c.sws_scale(
                    sws_ctx,
                    &frame.*.data,
                    &frame.*.linesize,
                    0,
                    codec_ctx.*.height,
                    &frame_rgb.*.data,
                    &frame_rgb.*.linesize,
                ), error.FailedToRescale);

                const fps = c.av_q2d(format_ctx.?.streams[video_stream_i].*.r_frame_rate);
                rl.WaitTime(1.0 / fps * 0.9);

                rl.UpdateTexture(tex, @ptrCast(*anyopaque, frame_rgb.*.data[0]));
                rl.DrawTexture(tex, 0, 0, rl.WHITE);

                rl.EndDrawing();
            }
        } else if (packet.stream_index == audio_stream_i) {
            _ = try check(c.avcodec_send_packet(audio_codec_ctx, &packet), error.ErrorDecodingPacket);

            var batch = std.ArrayList(i16).init(gpa);
            var i: u32 = 0;
            while (true) : (i += 1) {
                const r = c.avcodec_receive_frame(audio_codec_ctx, frame);
                if (r == c.AVERROR(c.EAGAIN) or r == AV_EOF) {
                    break;
                } else if (r < 0) {
                    return error.ErrorDecodingPacket;
                }

                const dest_samples = @intCast(i32, c.av_rescale_rnd(
                    c.swr_get_delay(swr_ctx, audio_codec_ctx.?.sample_rate) + frame.*.nb_samples,
                    audio_codec_ctx.?.sample_rate,
                    audio_codec_ctx.?.sample_rate,
                    c.AV_ROUND_UP,
                ));

                const dest_channels = 2;
                const dest_format = c.AV_SAMPLE_FMT_S16;
                var dest_data: [*c][*c]u8 = undefined;
                var dest_linesize: [dest_channels]i32 = [_]i32{ 0, 0 };
                _ = try check(c.av_samples_alloc_array_and_samples(&dest_data, &dest_linesize[0], dest_channels, dest_samples, dest_format, 0), error.AllocFailure);

                const rr = try check(c.swr_convert(swr_ctx, dest_data, dest_samples, &frame.*.data[0], frame.*.nb_samples), error.ConvertError);
                const dest_bufsize = c.av_samples_get_buffer_size(&dest_linesize, dest_channels, rr, dest_format, 1);
                var dest = std.mem.bytesAsSlice(i16, @alignCast(@alignOf(i16), dest_data[0][0..@intCast(usize, dest_bufsize)]));

                try batch.appendSlice(dest);

                c.av_freep(@ptrCast(*anyopaque, &dest_data[0]));
                c.av_freep(@ptrCast(*anyopaque, &dest_data));
            }

            var n = try gpa.create(@TypeOf(audio_batch_queue).Node);
            n.data = batch;
            audio_batch_queue.put(n);
        }
        c.av_packet_unref(&packet);
    }
}
