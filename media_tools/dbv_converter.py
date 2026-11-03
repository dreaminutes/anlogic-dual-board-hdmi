"""MP4 and other FFmpeg-readable media -> FPGA DBV1/DBV2. Python stdlib only."""
from pathlib import Path
from fractions import Fraction
import argparse
import hashlib
import json
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import wave

FRAME_BYTES = 640 * 480 * 2
MAX_AUDIO = 4063232
MAX_FRAMES = 6990


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def find_ffmpeg(value):
    candidates = [value] if value else [
        os.environ.get('FFMPEG_EXE'),
        str(Path(__file__).parent / 'runtime' / 'ffmpeg.exe'),
        shutil.which('ffmpeg'),
        str(Path(__file__).parent / 'ffmpeg.exe'),
    ]
    for name in candidates:
        if name and Path(name).is_file():
            return str(Path(name).resolve())
    raise ValueError('找不到 FFmpeg，请用 --ffmpeg "ffmpeg.exe的完整路径" 指定。')


def probe(exe, source, log):
    command = [exe, '-nostdin', '-hide_banner', '-i', str(source), '-map', '0:v:0',
               '-vf', 'showinfo', '-frames:v', '1', '-an', '-f', 'null', '-']
    result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=60)
    text = result.stderr.decode('utf-8', errors='replace')
    log.write(text.encode('utf-8'))
    if result.returncode:
        raise ValueError('无法读取视频，可能没有视频轨道或格式损坏。')
    rate = re.search(r'config in time_base:.*?frame_rate:\s*(\d+)/(\d+)', text)
    if not rate or int(rate[2]) == 0 or int(rate[1]) == 0:
        raise ValueError('无法识别源帧率，请检查视频。')
    duration = re.search(r'Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)', text)
    seconds = float(duration[1]) * 3600 + float(duration[2]) * 60 + float(duration[3]) if duration else None
    return Fraction(int(rate[1]), int(rate[2])), bool(re.search(r'Stream .*Audio:', text)), seconds


def timestamp(index, fps):
    return index * 90000 * fps.denominator // fps.numerator


def verify(path):
    """Independent readback: exact file size, timing, every frame and audio CRC."""
    import zlib
    with path.open('rb') as f:
        magic, ver, size, w, h, pixel, flags, num, den, frames, audio_bytes = struct.unpack('<4s6H4I', f.read(32))
        if (magic, ver) not in [(b'DBV1', 1), (b'DBV2', 2)] or (size, w, h, pixel, flags) != (32, 640, 480, 1, 1):
            raise ValueError('生成文件头校验失败。')
        if not 0 < frames <= MAX_FRAMES or not num or not den:
            raise ValueError('生成文件帧数/帧率校验失败。')
        if magic == b'DBV2':
            samples, crc, step, rate = struct.unpack('<4I', f.read(16))
            pcm = f.read(audio_bytes)
            if not (0 < audio_bytes <= MAX_AUDIO and audio_bytes % 4 == 0 and rate == 48000
                    and 0 <= audio_bytes - samples * 2 < 4 and step == (audio_bytes // 4 + 99) // 100
                    and len(pcm) == audio_bytes and zlib.crc32(pcm) & 0xffffffff == crc):
                raise ValueError('生成音频校验失败。')
            if abs(Fraction(samples, 48000) - Fraction(frames * den, num)) > Fraction(1, 48000):
                raise ValueError('音视频时长校验失败。')
        elif audio_bytes:
            raise ValueError('DBV1包含无效音频长度。')
        fps = Fraction(num, den)
        for index in range(frames):
            record = struct.unpack('<4I', f.read(16))
            pixels = f.read(FRAME_BYTES)
            if len(pixels) != FRAME_BYTES or record != (index, timestamp(index, fps),
                    timestamp(index + 1, fps) - timestamp(index, fps), zlib.crc32(pixels) & 0xffffffff):
                raise ValueError(f'第{index + 1}帧回读校验失败。')
        if f.read(1):
            raise ValueError('视频末尾存在额外数据。')
    return frames


def convert(args):
    import zlib
    source = args.source.resolve()
    if not source.is_file():
        raise ValueError('输入文件不存在。')
    if not re.fullmatch(r'[A-Za-z0-9_]{1,8}', args.name):
        raise ValueError('--name 只能使用1～8个英文字母、数字或下划线。')
    if not math.isfinite(args.start) or args.start < 0 or args.duration is not None and (not math.isfinite(args.duration) or args.duration <= 0):
        raise ValueError('起始时间须为非负数，截取时长须为正数。')
    if args.no_audio and args.export_wav:
        raise ValueError('--no-audio 与 --export-wav 不能同时使用。')
    out = args.output.resolve()
    video = out / (args.name.upper() + '.DBV')
    report = out / (args.name.upper() + '.manifest.json')
    wav = out / (args.name.upper() + '.WAV')
    targets = [video, report] + ([wav] if args.export_wav else [])
    if source in targets or any(f.exists() for f in targets):
        raise ValueError('输出文件已存在或与源文件相同。请更换输出目录/名称；工具不会覆盖旧文件。')
    exe = find_ffmpeg(args.ffmpeg)
    out.mkdir(parents=True, exist_ok=True)
    # Keep conversion errors available, even though incomplete artifacts are removed.
    with tempfile.NamedTemporaryFile(prefix='convert_', suffix='.log', dir=out, delete=False) as log:
        log_path = Path(log.name)
        native_fps, has_audio, source_duration = probe(exe, source, log)
        fps = native_fps if args.fps == 'auto' else Fraction(args.fps)
        if not fps > 0 or fps.numerator > 0xffffffff or fps.denominator > 0xffffffff or not 1 <= Fraction(90000, 1) / fps <= 0x7fffffff:
            raise ValueError('帧率不能用当前90kHz时间戳表示。')
        if source_duration is not None and args.start >= source_duration:
            raise ValueError('截取起点超过视频时长。')
        estimate = min(source_duration - args.start, args.duration) if source_duration is not None and args.duration is not None else args.duration if args.duration is not None else source_duration - args.start if source_duration is not None else None
        if not args.no_audio and estimate is not None and estimate > MAX_AUDIO / 96000:
            raise ValueError('原声超过约42.3秒缓存上限。请用 --duration 40 截取，或 --no-audio 仅转画面。')
        print(f'输出：640×480 RGB565，{fps} FPS，' + ('不含原声(DBV1)' if args.no_audio else '内嵌48kHz原声(DBV2)' if has_audio else '源文件无音轨，内嵌静音(DBV2)'), flush=True)
        original_sha = sha(source)
        common = [exe, '-nostdin', '-hide_banner', '-loglevel', 'error', '-ss', str(args.start), '-i', str(source)]
        with tempfile.TemporaryDirectory(prefix='.dbv_work_', dir=out) as temp:
            temp = Path(temp)
            raw_video = temp / 'frames.bin'
            vf = f'fps={fps.numerator}/{fps.denominator},scale=640:480:force_original_aspect_ratio=decrease,pad=640:480:(ow-iw)/2:(oh-ih)/2,setsar=1'
            command = common + (['-t', str(args.duration)] if args.duration is not None else []) + ['-map', '0:v:0', '-an', '-vf', vf, '-pix_fmt', 'rgb565le', '-f', 'rawvideo', 'pipe:1']
            frames = 0
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=log)
            try:
                with raw_video.open('xb') as f:
                    while True:
                        pixels = bytearray()
                        while len(pixels) < FRAME_BYTES:
                            chunk = process.stdout.read(FRAME_BYTES - len(pixels))
                            if not chunk:
                                break
                            pixels.extend(chunk)
                        if not pixels:
                            break
                        if len(pixels) != FRAME_BYTES:
                            raise ValueError('转换得到不完整视频帧。')
                        if frames >= MAX_FRAMES or timestamp(frames + 1, fps) > 0xffffffff:
                            raise ValueError('视频超过当前硬件帧数/时间戳上限。')
                        if not args.no_audio and math.ceil(Fraction((frames + 1) * fps.denominator * 48000, fps.numerator)) * 2 > MAX_AUDIO:
                            raise ValueError('转换后的原声超过缓存上限，请缩短片段或使用 --no-audio。')
                        f.write(struct.pack('<4I', frames, timestamp(frames, fps), timestamp(frames + 1, fps) - timestamp(frames, fps), zlib.crc32(pixels) & 0xffffffff))
                        f.write(pixels)
                        frames += 1
                        if frames % 100 == 0:
                            print(f'已转换 {frames} 帧', flush=True)
                if process.wait() != 0 or not frames:
                    raise ValueError(f'视频转换失败或无可用帧，日志：{log_path}')
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process.stdout.close()
            samples = round(Fraction(frames * fps.denominator * 48000, fps.numerator))
            pcm = b''
            if not args.no_audio:
                if has_audio:
                    audio_cmd = common + ['-map', '0:a:0', '-vn', '-af', f'aresample=48000:async=1:first_pts=0,apad,atrim=end_sample={samples}', '-ac', '1', '-ar', '48000', '-c:a', 'pcm_s16le', '-f', 's16le', 'pipe:1']
                    result = subprocess.run(audio_cmd, stdout=subprocess.PIPE, stderr=log, timeout=300)
                    if result.returncode:
                        raise ValueError(f'原声提取失败，日志：{log_path}')
                    pcm = result.stdout
                else:
                    pcm = bytes(samples * 2)
                if len(pcm) != samples * 2:
                    raise ValueError('提取的原声音长不正确。')
                pcm += bytes((-len(pcm)) % 4)
                if len(pcm) > MAX_AUDIO:
                    raise ValueError('原声超过缓存容量。')
            partial = temp / 'complete.DBV'
            magic = b'DBV1' if args.no_audio else b'DBV2'
            with partial.open('xb') as f:
                f.write(struct.pack('<4s6H4I', magic, 1 if args.no_audio else 2, 32, 640, 480, 1, 1, fps.numerator, fps.denominator, frames, len(pcm)))
                if pcm:
                    f.write(struct.pack('<4I', samples, zlib.crc32(pcm) & 0xffffffff, (len(pcm) // 4 + 99) // 100, 48000))
                    f.write(pcm)
                with raw_video.open('rb') as src:
                    shutil.copyfileobj(src, f, 1024 * 1024)
            if partial.stat().st_size > 0xffffffff:
                raise ValueError('输出超过FAT32单文件上限。')
            print('正在回读核验全部帧及音频…', flush=True)
            verify(partial)
            if sha(source) != original_sha:
                raise ValueError('转换期间源文件发生变化，请重新转换。')
            manifest = {'converter_version': '1.0', 'source': str(source), 'source_sha256': original_sha,
                        'source_unchanged': True, 'format': magic.decode(), 'video': video.name,
                        'sha256': sha(partial), 'bytes': partial.stat().st_size, 'width': 640, 'height': 480,
                        'fit': 'keep aspect ratio, black padding', 'source_fps': str(native_fps),
                        'output_fps': str(fps), 'frames': frames, 'duration_seconds': float(Fraction(frames, 1) / fps),
                        'start_seconds': args.start, 'original_audio': not args.no_audio and has_audio,
                        'audio_samples': samples if pcm else 0, 'audio_padded_bytes': len(pcm),
                        'audio_sample_rate': 48000 if pcm else None, 'all_frame_crc_verified': True,
                        'audio_crc_verified': bool(pcm), 'log': log_path.name,
                        'scope': 'Offline format/CRC validation; no FPGA hardware or sustained FPS claim.'}
            manifest_temp = temp / 'manifest.json'
            manifest_temp.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
            if args.export_wav:
                with wave.open(str(temp / 'audio.wav'), 'wb') as f:
                    f.setnchannels(1)
                    f.setsampwidth(2)
                    f.setframerate(48000)
                    f.writeframes(pcm[:samples * 2])
            # Windows rename refuses an existing destination. Never overwrite inputs.
            if any(f.exists() for f in targets):
                raise ValueError('转换期间输出文件已被其他程序创建，请更换名称。')
            partial.rename(video)
            manifest_temp.rename(report)
            if args.export_wav:
                (temp / 'audio.wav').rename(wav)
    print(f'完成：{video}\n帧数：{frames}，时长：{manifest["duration_seconds"]:.3f}秒，大小：{manifest["bytes"] / 1024 / 1024:.1f} MiB\n默认只需把 {video.name} 复制到TF卡根目录。', flush=True)


def main():
    parser = argparse.ArgumentParser(description='一条命令将视频转换为FPGA可播放DBV；不覆盖已有文件。')
    parser.add_argument('source', type=Path, help='输入MP4等视频的完整路径')
    parser.add_argument('-o', '--output', type=Path, default=Path.cwd() / 'converted_media', help='输出目录，默认当前目录下converted_media')
    parser.add_argument('--fps', default='20', help='默认20FPS；auto保留源标称帧率，也可指定30000/1001等')
    parser.add_argument('--name', default='VIDEO1', help='TF短文件名，不含扩展名，默认VIDEO1')
    parser.add_argument('--start', type=float, default=0, help='从第几秒开始')
    parser.add_argument('--duration', type=float, help='截取多少秒，不指定则到结尾')
    parser.add_argument('--no-audio', action='store_true', help='生成无原声DBV1，取消整段原声缓存时长限制')
    parser.add_argument('--export-wav', action='store_true', help='额外导出标准PCM WAV，不需要放到TF卡才能播原声')
    parser.add_argument('--ffmpeg', help='FFmpeg可执行文件路径，可省略')
    args = parser.parse_args()
    try:
        convert(args)
    except (ValueError, ZeroDivisionError, OSError, subprocess.SubprocessError, EOFError, struct.error) as e:
        print(f'转换失败：{e}', file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print('转换已取消，源文件不变。', file=sys.stderr)
        return 130
    return 0


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
    sys.exit(main())
