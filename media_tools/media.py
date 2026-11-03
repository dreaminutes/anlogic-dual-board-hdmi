"""V10 media preparation: DBV, strict PCM WAV, RGB24 BMP, and full-frame GIF."""
from pathlib import Path
import argparse
import datetime
import io
import json
import math
import os
import re
import struct
import subprocess
import sys
import tempfile
import wave

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import dbv_converter as dbv

EXTENSIONS = {
    'video': {'.mp4', '.mov', '.mkv', '.avi', '.webm', '.mpeg', '.mpg', '.m4v', '.ts'},
    'audio': {'.wav', '.mp3', '.flac', '.m4a', '.aac', '.ogg', '.wma', '.aiff', '.mp4', '.ape'},
    'image': {'.png', '.jpg', '.jpeg', '.bmp', '.webp', '.tif', '.tiff'},
    'gif': {'.gif'},
}
NAMES = {'video': 'VIDEO', 'audio': 'SONG', 'image': 'IMAGE', 'gif': 'ANIM'}
SUFFIXES = {'video': '.DBV', 'audio': '.WAV', 'image': '.BMP', 'gif': '.GIF'}


def new_output(kind):
    stamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    return HERE / 'output' / (stamp + '_' + kind)


def duration_args(args):
    return (['-ss', str(args.start)] if args.start else [])


def targets(source, out, name, kind):
    if not re.fullmatch(r'[A-Za-z0-9_]{1,8}', name):
        raise ValueError('输出名称必须是1～8个英文字母、数字或下划线，不带扩展名。')
    result = out / (name.upper() + SUFFIXES[kind])
    record = out / (name.upper() + '.json')
    if result.resolve() == source.resolve() or result.exists() or record.exists():
        raise ValueError(f'输出已存在或与输入相同：{result}。请换目录或名称。')
    out.mkdir(parents=True, exist_ok=True)
    return result, record


def publish(source, before, partial, result, record, details):
    if dbv.sha(source) != before:
        raise ValueError('转换期间输入文件发生变化，请重新转换。')
    if result.exists() or record.exists():
        raise ValueError('输出文件已被其他程序创建，请换目录。')
    details.update({'source': str(source), 'output': result.name,
                    'source_unchanged': True, 'bytes': partial.stat().st_size})
    if partial.stat().st_size > 0xffffffff:
        raise ValueError('结果超过FAT32单文件上限。')
    manifest = partial.parent / 'record.json'
    manifest.write_text(json.dumps(details, ensure_ascii=False, indent=2), encoding='utf-8')
    partial.rename(result)
    manifest.rename(record)
    print(f'完成：{result}', flush=True)
    return details


def convert_audio(source, out, name, args):
    result, record = targets(source, out, name, 'audio')
    before = dbv.sha(source)
    exe = dbv.find_ffmpeg(args.ffmpeg)
    command = [exe, '-nostdin', '-hide_banner', '-loglevel', 'error'] + duration_args(args)
    command += ['-i', str(source), '-map', '0:a:0', '-vn']
    if args.duration is not None:
        command += ['-t', str(args.duration)]
    command += ['-ac', '1', '-ar', '48000', '-c:a', 'pcm_s16le', '-f', 's16le', 'pipe:1']
    with tempfile.TemporaryDirectory(prefix='.wav_work_', dir=out) as work:
        work = Path(work)
        partial = work / 'audio.wav'
        with (work / 'ffmpeg.log').open('wb+') as log:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=log)
            written = 0
            try:
                with wave.open(str(partial), 'wb') as wav:
                    wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(48000)
                    while True:
                        chunk = process.stdout.read(65536)
                        if not chunk:
                            break
                        written += len(chunk)
                        if written > 0xffffffff - 44:
                            raise ValueError('音频超过FAT32/WAV文件大小上限。')
                        wav.writeframesraw(chunk)
                if process.wait():
                    log.seek(0)
                    raise ValueError('音频转换失败：' + log.read().decode('utf-8', errors='replace')[-1500:])
            finally:
                if process.poll() is None:
                    process.kill(); process.wait()
                process.stdout.close()
        with partial.open('rb') as handle:
            head = handle.read(44)
        if written < 2 or written % 2 or head[:4] != b'RIFF' or head[8:16] != b'WAVEfmt ' or head[36:40] != b'data':
            raise ValueError('音频无有效样本或44字节头验证失败。')
        if struct.unpack_from('<IHHIIHH', head, 16) != (16, 1, 1, 48000, 96000, 2, 16):
            raise ValueError('音频格式回读失败。')
        if struct.unpack_from('<I', head, 40)[0] != written or partial.stat().st_size != 44 + written:
            raise ValueError('音频数据长度验证失败。')
        return publish(source, before, partial, result, record,
                       {'format': 'PCM WAV', 'channels': 1, 'sample_rate': 48000,
                        'sample_bits': 16, 'header_bytes': 44, 'samples': written // 2,
                        'duration_seconds': written / 96000})


def rgb_on_black(image):
    from PIL import Image
    rgba = image.convert('RGBA')
    bg = Image.new('RGBA', rgba.size, (0, 0, 0, 255))
    return Image.alpha_composite(bg, rgba).convert('RGB')


def fit_canvas(image):
    from PIL import Image
    # Clamp the short side for extreme panoramas (e.g. 4097x1), where
    # integer rounding in a general-purpose contain helper can produce zero.
    scale = min(640 / image.width, 480 / image.height)
    size = (max(1, min(640, round(image.width * scale))),
            max(1, min(480, round(image.height * scale))))
    fit = image.resize(size, Image.Resampling.LANCZOS)
    canvas = Image.new('RGB', (640, 480), 'black')
    canvas.paste(fit, ((640-fit.width)//2, (480-fit.height)//2))
    return canvas


def convert_image(source, out, name, args):
    from PIL import Image, ImageOps
    result, record = targets(source, out, name, 'image')
    before = dbv.sha(source)
    with Image.open(source) as src:
        if getattr(src, 'n_frames', 1) != 1:
            raise ValueError('静态图片入口不接受多帧文件，请使用GIF入口。')
        image = rgb_on_black(ImageOps.exif_transpose(src))
        original_size = image.size
        if args.image_fit == 'canvas':
            image = fit_canvas(image)
        if not (1 <= image.width <= 4096 and 1 <= image.height <= 4096):
            raise ValueError('板端BMP宽高须为1～4096；请加 --image-fit canvas 适配至640×480。')
        with tempfile.TemporaryDirectory(prefix='.bmp_work_', dir=out) as work:
            partial = Path(work) / 'image.bmp'
            image.save(partial, format='BMP')
            with partial.open('rb') as handle:
                head = handle.read(54)
            if head[:2] != b'BM' or struct.unpack_from('<H', head, 28)[0] != 24 or struct.unpack_from('<I', head, 30)[0] != 0:
                raise ValueError('BMP必须是未压缩24位格式。')
            with Image.open(partial) as decoded:
                if decoded.size != image.size or decoded.convert('RGB').tobytes() != image.tobytes():
                    raise ValueError('BMP回读像素验证失败。')
            return publish(source, before, partial, result, record,
                           {'format': 'BMP', 'bits_per_pixel': 24, 'compression': 0,
                            'source_size': list(original_size), 'output_size': list(image.size),
                            'fit': args.image_fit, 'alpha_background': 'black', 'exif_orientation_applied': True})


def skip_subblocks(blob, pos):
    while True:
        if pos >= len(blob):
            raise ValueError('GIF编码器返回不完整数据。')
        size = blob[pos]; pos += 1
        if size == 0:
            return pos
        pos += size
        if pos > len(blob):
            raise ValueError('GIF数据块截断。')


def gif_frame_blocks(rgb):
    """Use Pillow's public GIF encoder; retain its LZW stream and localize the palette.

    GIF89a image descriptor + local table + data. Encoding one full frame at a
    time avoids retaining every RGB frame in RAM. No private Pillow APIs used.
    """
    from PIL import Image
    pal = rgb.quantize(colors=256, method=Image.Quantize.MEDIANCUT,
                       dither=Image.Dither.FLOYDSTEINBERG)
    stream = io.BytesIO()
    pal.save(stream, format='GIF', optimize=False, interlace=False)
    blob = stream.getvalue()
    packed = blob[10]
    if not packed & 128:
        raise ValueError('GIF单帧缺少调色板。')
    color_bits = packed & 7
    palette_size = 3 * (2 ** (color_bits + 1))
    palette = blob[13:13+palette_size]
    pos = 13+palette_size
    while blob[pos] == 0x21:
        pos = skip_subblocks(blob, pos+2)
    if blob[pos] != 0x2c:
        raise ValueError('GIF单帧描述无效。')
    descriptor = bytearray(blob[pos:pos+10])
    pos += 10
    if descriptor[9] & 128:
        color_bits = descriptor[9] & 7
        size = 3*(2**(color_bits+1))
        palette = blob[pos:pos+size]
        pos += size
    if struct.unpack('<4H', descriptor[1:9]) != (0, 0, 640, 480):
        raise ValueError('GIF单帧尺寸错误。')
    descriptor[9] = (descriptor[9] & 64) | 128 | color_bits
    end = skip_subblocks(blob, pos+1)
    return bytes(descriptor) + palette + blob[pos:end]


def convert_gif(source, out, name, args):
    from PIL import Image
    result, record = targets(source, out, name, 'gif')
    before = dbv.sha(source)
    delays = []
    with Image.open(source) as src:
        if src.format != 'GIF':
            raise ValueError('动图入口目前接受GIF文件。')
        count = getattr(src, 'n_frames', 1)
        loop = src.info.get('loop')
        source_size = src.size
        with tempfile.TemporaryDirectory(prefix='.gif_work_', dir=out) as work:
            partial = Path(work) / 'animation.gif'
            with partial.open('xb') as output:
                # GIF89a logical screen, no global table; every frame has a table.
                output.write(b'GIF89a' + struct.pack('<HHBBB', 640, 480, 0x70, 0, 0))
                if loop is not None:
                    output.write(b'!\xff\x0bNETSCAPE2.0\x03\x01' + struct.pack('<H', int(loop)) + b'\0')
                for index in range(count):
                    src.seek(index)
                    # Pillow composites disposal/local/transparency before RGBA conversion.
                    rgb = fit_canvas(rgb_on_black(src))
                    delay_ms = int(src.info.get('duration', 100))
                    if delay_ms <= 0:
                        delay_ms = 100
                    delay_cs = max(1, min(65535, (delay_ms+5)//10))
                    delays.append(delay_cs*10)
                    output.write(b'!\xf9\x04\x04' + struct.pack('<H', delay_cs) + b'\0\0')
                    output.write(gif_frame_blocks(rgb))
                    if (index+1) % 50 == 0:
                        print(f'已处理GIF {index+1}/{count}帧', flush=True)
                output.write(b';')
            actual_delays = []
            with Image.open(partial) as check:
                if check.size != (640, 480) or check.n_frames != count or check.info.get('loop') != loop:
                    raise ValueError('GIF画布、帧数或循环参数回读失败。')
                for index in range(count):
                    check.seek(index); check.load()
                    actual_delays.append(check.info.get('duration'))
                    if check.size != (640, 480):
                        raise ValueError('GIF帧尺寸回读失败。')
            if actual_delays != delays:
                raise ValueError('GIF帧延时回读失败。')
            return publish(source, before, partial, result, record,
                           {'format': 'GIF89a', 'source_size': list(source_size), 'output_size': [640,480],
                            'frames': count, 'duration_ms': sum(delays), 'frame_delays_ms': delays,
                            'loop': loop, 'full_opaque_frames': True, 'colors_per_frame': 256,
                            'fit': 'keep aspect ratio, black padding', 'zero_delay_normalized_ms': 100})


def collect_sources(values, kind):
    paths = []
    for value in values:
        path = Path(value).expanduser().resolve()
        if path.is_dir():
            paths.extend(p for p in sorted(path.iterdir(), key=lambda p:p.name.lower())
                         if p.is_file() and p.suffix.lower() in EXTENSIONS[kind])
        elif path.is_file():
            paths.append(path)
        else:
            raise ValueError(f'输入路径不存在：{path}')
    result = list(dict.fromkeys(paths))
    if not result:
        raise ValueError(f'没有找到可转换文件。请将素材放入 input/{kind}，或拖文件到相应CMD。')
    return result


def wizard():
    print('V10 素材转换工具\n1 视频→DBV  2 音频→WAV  3 静态图片→BMP  4 动图→GIF')
    kinds = {'1':'video', '2':'audio', '3':'image', '4':'gif'}
    kind = kinds.get(input('请选择1～4：').strip())
    if not kind:
        raise ValueError('请选择1～4。')
    raw = input(f'输入文件或目录路径；直接回车使用 input/{kind}：').strip().strip('"')
    cmd = [kind] + ([raw] if raw else [])
    if kind == 'video':
        if input('原声模式：1 带原声（单段≤42秒），2 无原声；默认1：').strip() == '2':
            cmd.append('--no-audio')
    if kind == 'image':
        if input('图片尺寸：1 保留原尺寸，2 等比例适配640×480；默认1：').strip() == '2':
            cmd.extend(['--image-fit', 'canvas'])
    return cmd


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        argv = wizard()
    parser = argparse.ArgumentParser(description='V10四类素材转换；不覆盖旧输出、不修改输入、不自动写TF卡。')
    parser.add_argument('kind', choices=EXTENSIONS)
    parser.add_argument('inputs', nargs='*', help='一个或多个文件/目录；目录只读当前层')
    parser.add_argument('-o','--output', type=Path, help='输出目录；默认output下的新批次')
    parser.add_argument('--name', help='单文件输出短名称，不含扩展名')
    parser.add_argument('--ffmpeg', help='可选FFmpeg路径')
    parser.add_argument('--fps', default='20', help='视频帧率，默认20；auto使用源标称帧率')
    parser.add_argument('--no-audio', action='store_true', help='视频输出DBV1，不含原声')
    parser.add_argument('--start', type=float, default=0, help='视频/音频截取起点，单位秒')
    parser.add_argument('--duration', type=float, help='视频/音频截取时长，单位秒')
    parser.add_argument('--image-fit', choices=['native','canvas'], default='native', help='静态图保留原尺寸或适配640×480')
    args = parser.parse_args(argv)
    if not math.isfinite(args.start) or args.start < 0 or args.duration is not None and (not math.isfinite(args.duration) or args.duration <= 0):
        raise ValueError('起始时间须为非负数，截取时长须为正数。')
    if args.kind not in ('video','audio') and (args.start or args.duration is not None):
        raise ValueError('--start/--duration只用于视频与音频。')
    if args.kind != 'video' and args.no_audio:
        raise ValueError('--no-audio只用于视频。')
    sources = collect_sources(args.inputs or [HERE/'input'/args.kind], args.kind)
    if args.name and len(sources) != 1:
        raise ValueError('--name只用于单文件；批量转换自动编号。')
    out = (args.output or new_output(args.kind)).resolve()
    print(f'本批次共{len(sources)}个文件，输出目录：{out}', flush=True)
    if args.kind == 'audio' and len(sources) > 2:
        print('提示：可以转换多首，但V10背景音乐只读取TF根目录前两个WAV。', flush=True)
    failures = []
    supplied_name = args.name
    for i, source in enumerate(sources, 1):
        name = supplied_name or (NAMES[args.kind] + str(i))
        print(f'[{i}/{len(sources)}] {source.name}', flush=True)
        try:
            if args.kind == 'video':
                video_args = argparse.Namespace(**vars(args))
                video_args.source, video_args.output, video_args.name, video_args.export_wav = source, out, name, False
                dbv.convert(video_args)
            elif args.kind == 'audio':
                convert_audio(source, out, name, args)
            elif args.kind == 'image':
                convert_image(source, out, name, args)
            else:
                convert_gif(source, out, name, args)
        except (ValueError, OSError, EOFError, struct.error, subprocess.SubprocessError, ZeroDivisionError) as e:
            print(f'失败：{source.name}：{e}', file=sys.stderr, flush=True)
            failures.append({'file': str(source), 'error': str(e)})
    if failures:
        out.mkdir(parents=True, exist_ok=True)
        failure_report = out / ('failures_' + datetime.datetime.now().strftime('%H%M%S_%f') + '.json')
        failure_report.write_text(json.dumps(failures, ensure_ascii=False, indent=2), encoding='utf-8')
        print(f'{len(failures)}个文件失败，成功文件保留；请查看上方提示。', file=sys.stderr)
        return 1
    print('全部完成。只把需要的 .DBV/.WAV/.BMP/.GIF 复制到TF卡根目录，JSON和日志不用复制。')
    return 0


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('\n已取消，输入文件不变。', file=sys.stderr)
        sys.exit(130)
    except (ValueError, OSError, ImportError, EOFError) as e:
        print(f'无法转换：{e}', file=sys.stderr)
        sys.exit(1)
