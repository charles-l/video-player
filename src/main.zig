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

const AudioBatch = struct {
    buf: std.ArrayList(i16),
    pts: i64,
};

const AV_EOF = std.mem.readPackedInt(u32, "EOF ", 0, .Little);

var audio_codec_ctx: ?*c.AVCodecContext = null;
var audio_batch_queue = std.atomic.Queue(AudioBatch).init();

var audio_packet_queue = std.atomic.Queue(*c.AVPacket).init();
var video_packet_queue = std.atomic.Queue(*c.AVPacket).init();
const QueueNode = std.atomic.Queue(*c.AVPacket).Node;

var flush_packet: c.AVPacket = undefined;

var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
const gpa = general_purpose_allocator.allocator();

fn clearQueue(comptime T: type, queue: *std.atomic.Queue(T)) void {
    while (queue.get()) |x| {
        if (T == *c.AVPacket) {
            c.av_packet_free(@ptrCast([*c][*c]c.AVPacket, &x.data));
        } else if (T == AudioBatch) {
            x.data.buf.deinit();
        }
        gpa.destroy(x);
    }
}

/// Returns true when a new packet is needed
fn decodeFrame(ctx: *c.AVCodecContext, frame: *c.AVFrame) !bool {
    const r = c.avcodec_receive_frame(ctx, frame);
    if (r == c.AVERROR(c.EAGAIN) or r == AV_EOF) {
        return true;
    } else if (r < 0) {
        return error.ErrorDecodingPacket;
    }
    switch (ctx.avctx.codec_type) {
        c.AVMEDIA_TYPE_VIDEO => {},
    }
}

fn getMasterClock() f64 {
    return c.av_q2d(audio_codec_ctx.?.pkt_timebase) * @intToFloat(f64, audio_clock);
}

export fn audioCallback(buffer: ?*anyopaque, frames: u32) void {
    var buf = @ptrCast([*]i16, @alignCast(@alignOf(i16), buffer))[0 .. frames * 2];
    var frames_filled: usize = 0;

    @memset(@ptrCast([*]u8, buf), 0, buf.len * @sizeOf(i16));
    while (frames_filled < buf.len) {
        if (audio_batch_queue.get()) |batch| {
            audio_clock = batch.*.data.pts;
            if (frames_filled + batch.data.buf.items.len < buf.len) {
                std.mem.copy(i16, buf[frames_filled..], batch.data.buf.items);
                frames_filled += batch.data.buf.items.len;
                batch.data.buf.deinit();
                gpa.destroy(batch);
            } else {
                std.mem.copy(i16, buf[frames_filled..], batch.data.buf.items[0 .. buf.len - frames_filled]);

                var leftover = std.ArrayList(i16).init(gpa);
                leftover.appendSlice(batch.data.buf.items[buf.len - frames_filled ..]) catch @panic("couldn't append");

                batch.data.buf.deinit();

                batch.data.buf = leftover;
                audio_batch_queue.unget(batch);

                frames_filled += buf.len - frames_filled;
            }
        } else {
            //print("starved\n", .{});
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

const PlayerContext = struct {
    format_ctx: *c.AVFormatContext,
    video_stream_i: usize,
    audio_stream_i: usize,
};

fn readThread(ctx: *PlayerContext) !void {
    var packet = c.av_packet_alloc();
    defer c.av_packet_free(&packet);

    while (!quit) {
        var packet_i: u32 = 0;

        if (seek) |t| {
            const seek_target_video = c.av_rescale_q(t, c.AV_TIME_BASE_Q, ctx.format_ctx.streams[ctx.video_stream_i].*.time_base);
            const seek_target_audio = c.av_rescale_q(t, c.AV_TIME_BASE_Q, ctx.format_ctx.streams[ctx.audio_stream_i].*.time_base);
            var flags: i32 = 0;
            if (@intToFloat(f32, t) < getMasterClock()) {
                print("seek backwards\n", .{});
                flags = c.AVSEEK_FLAG_BACKWARD;
            }
            print("{} {}\n", .{
                t,
                seek_target_video,
            });
            _ = try check(c.av_seek_frame(ctx.format_ctx, @intCast(i32, ctx.audio_stream_i), seek_target_audio, flags), error.SeekAudioError);
            _ = try check(c.av_seek_frame(ctx.format_ctx, @intCast(i32, ctx.video_stream_i), seek_target_video, flags), error.SeekVideoError);

            clearQueue(*c.AVPacket, &video_packet_queue);
            clearQueue(*c.AVPacket, &audio_packet_queue);
            clearQueue(AudioBatch, &audio_batch_queue);

            {
                var qpacket = try gpa.create(QueueNode);
                qpacket.data = &flush_packet;
                video_packet_queue.put(qpacket);
            }

            {
                var qpacket = try gpa.create(QueueNode);
                qpacket.data = &flush_packet;
                audio_packet_queue.put(qpacket);
            }
            seek = null;
        }
        // FIXME: this av_read_frame call still seems to be leaking a bit of memory somewhere...
        while (c.av_read_frame(ctx.format_ctx, packet) >= 0) : (packet_i += 1) {
            var packet1 = c.av_packet_alloc();
            errdefer c.av_packet_free(&packet1);

            c.av_packet_move_ref(packet1, packet);

            var qpacket = try gpa.create(QueueNode);
            qpacket.data = packet1;

            if (packet1.*.stream_index == ctx.video_stream_i) {
                video_packet_queue.put(qpacket);
            } else if (packet1.*.stream_index == ctx.audio_stream_i) {
                audio_packet_queue.put(qpacket);
            } else {
                print("drop packet\n", .{});
                gpa.destroy(qpacket);
            }
            c.av_packet_unref(packet);
        }

        std.time.sleep(1_000);
    }
}

var frame_rgb: ?*c.AVFrame = null;
var frame_updated = false;
var frame_lock = std.Thread.Mutex{};

var audio_clock: i64 = 0;

fn videoThread(video_codec_ctx: *c.AVCodecContext) !void {
    var frame = try check(c.av_frame_alloc(), error.AllocFailure);
    defer c.av_frame_free(&frame);

    frame_rgb = try check(c.av_frame_alloc(), error.AllocFailure);
    defer c.av_frame_free(&frame_rgb);

    const num_bytes = @intCast(usize, c.av_image_get_buffer_size(c.AV_PIX_FMT_RGB24, video_codec_ctx.*.width, video_codec_ctx.*.height, 32));
    const buffer = try gpa.alloc(u8, num_bytes);
    defer gpa.free(buffer);

    _ = try check(c.av_image_fill_arrays(
        &frame_rgb.?.*.data,
        &frame_rgb.?.*.linesize,
        &buffer[0],
        c.AV_PIX_FMT_RGB24,
        video_codec_ctx.*.width,
        video_codec_ctx.*.height,
        32,
    ), error.FailedToImageFillArray);

    const sws_ctx = c.sws_getContext(
        video_codec_ctx.*.width,
        video_codec_ctx.*.height,
        video_codec_ctx.*.pix_fmt,
        video_codec_ctx.*.width,
        video_codec_ctx.*.height,
        c.AV_PIX_FMT_RGB24,
        c.SWS_BILINEAR,
        null,
        null,
        null,
    );
    defer c.sws_freeContext(sws_ctx);

    while (!quit) {
        var qpacket = video_packet_queue.get();

        if (qpacket == null) {
            //std.debug.print("video starved\n", .{});
            continue;
        }

        defer gpa.destroy(qpacket.?);
        var packet = qpacket.?.data;

        if (packet == &flush_packet) {
            print("flush video\n", .{});
            c.avcodec_flush_buffers(video_codec_ctx);
            continue;
        }

        _ = try check(c.avcodec_send_packet(video_codec_ctx, packet), error.DecodingPacket);

        while (true) {
            const r = c.avcodec_receive_frame(video_codec_ctx, frame);
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
                video_codec_ctx.*.height,
                &frame_rgb.?.*.data,
                &frame_rgb.?.*.linesize,
            ), error.FailedToRescale);

            while (audio_clock < frame.*.pts) {
                std.atomic.spinLoopHint();
            }

            {
                frame_lock.lock();
                frame_updated = true;
                frame_lock.unlock();
            }
        }

        c.av_packet_unref(packet);
    }
}

fn audioThread() !void {
    var frame = try check(c.av_frame_alloc(), error.AllocFailure);
    defer c.av_frame_free(&frame);

    var swr_ctx = try check(c.swr_alloc(), error.AllocFailure);
    defer c.swr_free(&swr_ctx);

    _ = try check(c.av_opt_set_chlayout(swr_ctx, "in_chlayout", &audio_codec_ctx.?.ch_layout, 0), error.FailedToSetOption);
    _ = try check(c.av_opt_set_int(swr_ctx, "in_sample_rate", audio_codec_ctx.?.sample_rate, 0), error.FailedToSetOption);
    _ = try check(c.av_opt_set_sample_fmt(swr_ctx, "in_sample_fmt", audio_codec_ctx.?.sample_fmt, 0), error.FailedToSetOption);

    _ = try check(c.av_opt_set_int(swr_ctx, "out_channel_layout", c.AV_CH_LAYOUT_STEREO, 0), error.FailedToSetOption);
    _ = try check(c.av_opt_set_int(swr_ctx, "out_sample_rate", audio_codec_ctx.?.sample_rate, 0), error.FailedToSetOption);
    _ = try check(c.av_opt_set_sample_fmt(swr_ctx, "out_sample_fmt", c.AV_SAMPLE_FMT_S16, 0), error.FailedToSetOption);

    _ = try check(c.swr_init(swr_ctx), error.FailedToInit);

    while (!quit) {
        var qpacket = audio_packet_queue.get();
        if (qpacket == null) {
            std.time.sleep(1_000_000);
            //std.debug.print("audio starved\n", .{});
            continue;
        }
        defer gpa.destroy(qpacket.?);

        var packet = qpacket.?.data;

        if (packet == &flush_packet) {
            print("flush audio\n", .{});
            c.avcodec_flush_buffers(audio_codec_ctx);
            continue;
        }

        var batch = std.ArrayList(i16).init(gpa);
        var pts: i64 = 0;

        _ = try check(c.avcodec_send_packet(audio_codec_ctx, packet), error.ErrorDecodingPacket);
        while (true) {
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
            pts = frame.*.pts;
            const dest_bufsize = c.av_samples_get_buffer_size(&dest_linesize, dest_channels, rr, dest_format, 1);
            var dest = std.mem.bytesAsSlice(i16, @alignCast(@alignOf(i16), dest_data[0][0..@intCast(usize, dest_bufsize)]));

            try batch.appendSlice(dest);

            c.av_freep(@ptrCast(*anyopaque, &dest_data[0]));
            c.av_freep(@ptrCast(*anyopaque, &dest_data));
            c.av_packet_unref(packet);
        }

        var n = try gpa.create(@TypeOf(audio_batch_queue).Node);
        n.data = AudioBatch{ .buf = batch, .pts = pts };
        audio_batch_queue.put(n);
    }
}

const windowWidth = 800;
const windowHeight = 600;
var quit = false;
// FIXME: not threadsafe I don't think...
var seek: ?i64 = null;

pub fn main() !void {
    defer std.debug.assert(!general_purpose_allocator.deinit());

    defer clearQueue(AudioBatch, &audio_batch_queue);
    defer clearQueue(*c.AVPacket, &audio_packet_queue);
    defer clearQueue(*c.AVPacket, &video_packet_queue);

    rl.InitWindow(windowWidth, windowHeight, "vid");
    defer rl.CloseWindow();

    rl.InitAudioDevice();
    defer rl.CloseAudioDevice();

    c.av_init_packet(&flush_packet);
    var flush_str = [_]u8{ 'f', 'l', 'u', 's', 'h', 0 };
    flush_packet.data = &flush_str;
    var format_ctx: ?*c.AVFormatContext = null;
    //_ = try check(c.avformat_open_input(&format_ctx, "/home/nc/Downloads/Mice and cheese - Animation-kMYokm13GyM.mkv", null, null), error.OpeningFile);
    _ = try check(c.avformat_open_input(&format_ctx, "/home/nc/Downloads/5 Minutes of Battlefield 1 Domination Gameplay - 1080p, 60fps-5YdTrNmA7sQ.mkv", null, null), error.OpeningFile);
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

    audio_codec_ctx.?.pkt_timebase = format_ctx.?.streams[audio_stream_i].*.time_base;

    defer _ = c.avcodec_close(audio_codec_ctx);
    defer c.avcodec_free_context(&audio_codec_ctx);

    _ = try check(c.avcodec_open2(audio_codec_ctx, audio_codec, null), error.OpeningCodec);

    var audio_stream = rl.LoadAudioStream(@intCast(u32, audio_codec_ctx.?.sample_rate), 16, 2);
    rl.SetAudioStreamCallback(audio_stream, audioCallback);
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
    var video_codec_ctx = c.avcodec_alloc_context3(codec);
    _ = try check(c.avcodec_parameters_to_context(video_codec_ctx, format_ctx.?.streams[video_stream_i].*.codecpar), error.CodecSetup);

    defer _ = c.avcodec_close(video_codec_ctx);
    defer c.avcodec_free_context(&video_codec_ctx);

    _ = try check(c.avcodec_open2(video_codec_ctx, codec, null), error.OpeningCodec);

    var read_thread = try std.Thread.spawn(.{}, readThread, .{&PlayerContext{
        .format_ctx = format_ctx.?,
        .video_stream_i = video_stream_i,
        .audio_stream_i = audio_stream_i,
    }});
    try read_thread.setName("read_thread");
    defer read_thread.join();

    var video_thread = try std.Thread.spawn(.{}, videoThread, .{video_codec_ctx});
    try video_thread.setName("video_thread");
    defer video_thread.join();

    var audio_thread = try std.Thread.spawn(.{}, audioThread, .{});
    try audio_thread.setName("audio_thread");
    defer audio_thread.join();

    const img = rl.Image{
        .data = null,
        .width = video_codec_ctx.*.width,
        .height = video_codec_ctx.*.height,
        .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8,
        .mipmaps = 1,
    };

    const tex = rl.LoadTextureFromImage(img);
    defer rl.UnloadTexture(tex);

    while (!rl.WindowShouldClose()) {
        rl.BeginDrawing();
        rl.ClearBackground(rl.BLACK);

        // check for updated image
        if (frame_lock.tryLock()) {
            if (frame_updated) {
                frame_updated = false;
                rl.UpdateTexture(tex, @ptrCast(*anyopaque, frame_rgb.?.*.data[0]));
            }
            frame_lock.unlock();
        }

        const targetHeight = (windowWidth / @intToFloat(f32, video_codec_ctx.*.width)) * @intToFloat(f32, video_codec_ctx.*.height);
        rl.DrawTexturePro(
            tex,
            rl.Rectangle{ .x = 0, .y = 0, .width = @intToFloat(f32, video_codec_ctx.*.width), .height = @intToFloat(f32, video_codec_ctx.*.height) },
            rl.Rectangle{ .x = 0, .y = (windowHeight - targetHeight) / 2, .width = windowWidth, .height = targetHeight },
            rl.Vector2{ .x = 0, .y = 0 },
            0,
            rl.WHITE,
        );

        const duration = @intToFloat(f64, format_ctx.?.duration) / 1_000_000;
        const percentWatched = getMasterClock() / duration;

        rl.DrawRectangle(4, windowHeight - 24, windowWidth - 8, 20, rl.WHITE);
        rl.DrawRectangle(8, windowHeight - 20, @floatToInt(i32, (windowWidth - 16) * percentWatched), 12, rl.BLACK);

        var out_str = [1]u8{0} ** 64;
        _ = std.fmt.bufPrintZ(out_str[0..], "{d:0.2}", .{getMasterClock()}) catch unreachable;
        rl.DrawText(&out_str, 10, 10, 30, rl.GREEN);

        if (rl.IsMouseButtonReleased(rl.MOUSE_BUTTON_LEFT)) {
            const p = @intToFloat(f32, rl.GetMouseX()) / @intToFloat(f32, windowWidth);
            const t = @floatToInt(i64, @intToFloat(f32, format_ctx.?.duration) * p);
            seek = t;
        }

        rl.EndDrawing();
    }
    quit = true;
}
