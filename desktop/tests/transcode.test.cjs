const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {videoArgs} = require('../transcode-settings.cjs');

test('video preset requires Android-compatible H.264 Baseline 3.1 and AAC', () => {
  const args = videoArgs('input.mov','output.mp4');
  const option = key => args[args.indexOf(key)+1];
  assert.equal(option('-c:v'),'libx264');
  assert.equal(option('-profile:v'),'baseline');
  assert.equal(option('-level:v'),'3.1');
  assert.equal(option('-pix_fmt'),'yuv420p');
  assert.equal(option('-c:a'),'aac');
  assert.equal(option('-profile:a'),'aac_low');
  assert.equal(option('-movflags'),'+faststart');
  assert.match(option('-vf'),/fps=30/);
});

test('FFmpeg creates decodable baseline MP4 from landscape and portrait sources', t => {
  if (spawnSync('ffmpeg',['-version'],{encoding:'utf8'}).status !== 0 ||
      spawnSync('ffprobe',['-version'],{encoding:'utf8'}).status !== 0) {
    t.skip('FFmpeg/ffprobe not installed on this system');
    return;
  }
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'larp-video-test-'));
  try {
    for (const [orientation, size] of [['landscape','320x240'],['portrait','240x320']]) {
      const input=path.join(dir,orientation+'.avi'), output=path.join(dir,orientation+'.mp4');
      const source=spawnSync('ffmpeg',['-hide_banner','-loglevel','error','-y','-f','lavfi','-i','testsrc2=size='+size+':rate=25','-t','0.5','-c:v','mpeg4',input],{encoding:'utf8'});
      assert.equal(source.status,0,source.stderr);
      const encode=spawnSync('ffmpeg',['-loglevel','error',...videoArgs(input,output)],{encoding:'utf8'});
      assert.equal(encode.status,0,encode.stderr);
      assert.ok(fs.statSync(output).size>0);
      const probe=spawnSync('ffprobe',['-v','error','-select_streams','v:0','-show_entries','stream=codec_name,profile,level,pix_fmt,width,height','-of','json',output],{encoding:'utf8'});
      assert.equal(probe.status,0,probe.stderr);
      const stream=JSON.parse(probe.stdout).streams[0];
      assert.equal(stream.codec_name,'h264');
      assert.match(stream.profile,/Baseline/);
      assert.equal(stream.level,31);
      assert.equal(stream.pix_fmt,'yuv420p');
      assert.ok(stream.width*stream.height <= 1280*720);
      assert.equal(orientation==='portrait',stream.height>stream.width);
      const decode=spawnSync('ffmpeg',['-v','error','-xerror','-i',output,'-f','null','-'],{encoding:'utf8'});
      assert.equal(decode.status,0,decode.stderr);
    }
  } finally {fs.rmSync(dir,{recursive:true,force:true});}
});
