"""Offline regression using generated media; no personal assets or FPGA access."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import wave

from PIL import Image, ImageChops, ImageDraw, ImageStat

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
import dbv_converter as dbv
import media


class MediaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='v10_media_tests_')
        cls.root = Path(cls.temp.name) / '中文 带空格的路径'
        cls.root.mkdir()
        cls.ffmpeg = dbv.find_ffmpeg(None)
        cls.env = dict(os.environ, PYTHONUTF8='1', PYTHONDONTWRITEBYTECODE='1', MEDIA_NO_PAUSE='1')
        cls.png = cls.root / '透明图.png'
        Image.new('RGBA', (17, 11), (240, 20, 60, 128)).save(cls.png)
        cls.video = cls.root / '视频 带音轨.mkv'
        cls.video2 = cls.root / '另一视频.mkv'
        cmd = [cls.ffmpeg, '-nostdin', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=32x24:rate=10',
               '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100', '-t', '0.3',
               '-c:v', 'ffv1', '-c:a', 'pcm_s16le', str(cls.video)]
        subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        cls.video2.write_bytes(cls.video.read_bytes())
        cls.gif = cls.root / '有透明和局部帧.gif'
        palette = [0,0,0,255,30,30,30,255,30,30,30,255,255,255,30] + [0,0,0]*251
        frames=[]
        for i in range(4):
            im=Image.new('P',(40,30),0);im.putpalette(palette)
            ImageDraw.Draw(im).rectangle((4+i*8,5,15+i*8,20),fill=i+1)
            frames.append(im)
        frames[0].save(cls.gif,save_all=True,append_images=frames[1:],duration=[30,70,110,50],
                       loop=2,transparency=0,disposal=[1,2,3,1],optimize=False)
        cls.original = {p:hashlib.sha256(p.read_bytes()).hexdigest() for p in [cls.png,cls.video,cls.video2,cls.gif]}

    @classmethod
    def tearDownClass(cls):
        for p,digest in cls.original.items():
            assert hashlib.sha256(p.read_bytes()).hexdigest()==digest, 'Input changed'
        cls.temp.cleanup()

    def cli(self, kind, sources, out, *opts, success=True):
        command=[sys.executable,'-B','-X','utf8',str(HERE/'media.py'),kind,*map(str,sources),'-o',str(out),*opts]
        r=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=self.env,timeout=180)
        text=(r.stdout+r.stderr).decode('utf-8',errors='replace')
        self.assertEqual(r.returncode==0,success,text)
        return text

    def test_video_dbv2_batch_and_crc(self):
        out=self.root/'视频批量'
        self.cli('video',[self.video,self.video2],out)
        for name in ['VIDEO1','VIDEO2']:
            p=out/(name+'.DBV')
            self.assertTrue(p.exists())
            frames=dbv.verify(p)
            m=json.loads((out/(name+'.manifest.json')).read_text(encoding='utf-8'))
            self.assertEqual(m['output_fps'],'20')
            self.assertEqual(m['format'],'DBV2')
            self.assertGreater(frames,0)
            self.assertTrue(m['original_audio'])
            self.assertEqual(m['audio_sample_rate'],48000)
        # Ensure integrity checks actually reject a corrupted payload.
        corrupted=self.root/'CORRUPT.DBV'
        raw=bytearray((out/'VIDEO1.DBV').read_bytes());raw[-1]^=1;corrupted.write_bytes(raw)
        with self.assertRaises(ValueError):dbv.verify(corrupted)

    def test_video_no_audio(self):
        out=self.root/'无原声'
        self.cli('video',[self.video],out,'--no-audio','--name','SILENT')
        p=out/'SILENT.DBV'
        self.assertEqual(p.read_bytes()[:4],b'DBV1')
        self.assertGreater(dbv.verify(p),0)

    def test_long_video_rejected_before_publication(self):
        source=self.root/'长43秒.mkv'
        subprocess.run([self.ffmpeg,'-nostdin','-v','error','-f','lavfi','-i','color=c=blue:s=8x8:r=1',
                        '-t','43','-c:v','ffv1',str(source)],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        out=self.root/'超限'
        text=self.cli('video',[source],out,success=False)
        self.assertIn('42.3',text)
        self.assertFalse(list(out.glob('*.DBV')))

    def test_audio_strict_header_and_no_overwrite(self):
        out=self.root/'音频'
        self.cli('audio',[self.video],out)
        p=out/'SONG1.WAV';raw=p.read_bytes()
        self.assertEqual(raw[:4],b'RIFF');self.assertEqual(raw[8:16],b'WAVEfmt ')
        self.assertEqual(raw[36:40],b'data')
        self.assertEqual(struct.unpack_from('<IHHIIHH',raw,16),(16,1,1,48000,96000,2,16))
        self.assertEqual(struct.unpack_from('<I',raw,40)[0],len(raw)-44)
        with wave.open(str(p),'rb') as w:
            self.assertEqual((w.getnchannels(),w.getsampwidth(),w.getframerate()),(1,2,48000))
            self.assertGreater(w.getnframes(),0)
        digest=hashlib.sha256(raw).hexdigest()
        self.cli('audio',[self.video],out,success=False)
        self.assertEqual(hashlib.sha256(p.read_bytes()).hexdigest(),digest)

    def test_bmp_native_and_canvas(self):
        out=self.root/'静态'
        self.cli('image',[self.png],out)
        p=out/'IMAGE1.BMP';raw=p.read_bytes()
        self.assertEqual(struct.unpack_from('<H',raw,28)[0],24)
        self.assertEqual(struct.unpack_from('<I',raw,30)[0],0)
        with Image.open(p) as im:
            self.assertEqual(im.size,(17,11))
            self.assertEqual(im.getpixel((0,0)),(120,10,30))
        out2=self.root/'静态适配'
        self.cli('image',[self.png],out2,'--image-fit','canvas')
        with Image.open(out2/'IMAGE1.BMP') as im:self.assertEqual(im.size,(640,480))

    def test_bmp_large_and_exif(self):
        large=self.root/'超大宽度.png';Image.new('RGB',(4097,1),'red').save(large)
        out=self.root/'大图拒绝';self.cli('image',[large],out,success=False)
        self.assertFalse(list(out.glob('*.BMP')))
        self.cli('image',[large],self.root/'大图适配','--image-fit','canvas')
        oriented=self.root/'方向.jpg';im=Image.new('RGB',(3,2),'blue')
        exif=Image.Exif();exif[274]=6;im.save(oriented,exif=exif)
        self.cli('image',[oriented],self.root/'方向输出')
        with Image.open(self.root/'方向输出'/'IMAGE1.BMP') as check:self.assertEqual(check.size,(2,3))

    def test_gif_timing_loop_composition_and_geometry(self):
        out=self.root/'GIF输出';self.cli('gif',[self.gif],out)
        p=out/'ANIM1.GIF'
        with Image.open(self.gif) as src, Image.open(p) as dst:
            self.assertEqual((dst.n_frames,dst.size,dst.info.get('loop')),(4,(640,480),2))
            for i,delay in enumerate([30,70,110,50]):
                src.seek(i);dst.seek(i)
                self.assertEqual(dst.info['duration'],delay)
                self.assertEqual(dst.disposal_method,1)
                target=media.fit_canvas(media.rgb_on_black(src))
                mean=ImageStat.Stat(ImageChops.difference(target,dst.convert('RGB'))).mean
                self.assertLess(max(mean),3.0)
        record=json.loads((out/'ANIM1.json').read_text(encoding='utf-8'))
        self.assertTrue(record['full_opaque_frames'])
        self.assertEqual(record['duration_ms'],260)

    def test_published_windows_wrappers(self):
        if os.name != 'nt':
            self.skipTest('Windows CMD wrappers')
        help_result=subprocess.run(['cmd.exe','/d','/c',str(HERE/'00_启动转换工具.cmd'),'--help'],
                                   stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=self.env,timeout=30)
        self.assertEqual(help_result.returncode,0)
        for filename,source,opts in [
            ('01_视频转DBV.cmd',self.video,['--no-audio','--duration','0.1']),
            ('02_音频转WAV.cmd',self.video,[]),
            ('03_静态图片转BMP.cmd',self.png,[]),
            ('04_动图转GIF.cmd',self.gif,[]),
        ]:
            command=['cmd.exe','/d','/c',str(HERE/filename),str(source),'-o',str(self.root/('CMD_'+filename[:2])),*opts]
            for expected in (0,1):
                result=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=self.env,timeout=180)
                self.assertEqual(result.returncode,expected,(filename,(result.stdout+result.stderr).decode('utf-8',errors='replace')))

    def test_bad_inputs_leave_no_fake_media(self):
        bad=self.root/'损坏.png';bad.write_bytes(b'not a picture')
        out=self.root/'坏图'
        self.cli('image',[bad],out,success=False)
        self.assertFalse(list(out.glob('*.BMP')))
        missing=self.root/'不存在.mp3'
        self.cli('audio',[missing],self.root/'缺失',success=False)
        self.cli('image',[self.png],self.root/'坏名','--name','名称',success=False)


if __name__=='__main__':
    unittest.main(verbosity=2)
