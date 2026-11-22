import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { prepareForPlayers } from '../src/compress.ts';

function withDesktop(t: { after: (callback: () => void) => void }, transcode: (kind: 'video'|'audio', name: string, bytes: ArrayBuffer, onProgress:(percent:number)=>void) => Promise<{name:string;bytes:ArrayBuffer}|null>) {
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, 'window');
  const previousStorage = Object.getOwnPropertyDescriptor(globalThis, 'localStorage');
  Object.defineProperty(globalThis, 'window', { configurable: true, value: {larpDesktop: {transcode}} });
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: {getItem: () => 'off'} });
  t.after(() => {
    if(previousWindow)Object.defineProperty(globalThis, 'window', previousWindow);
    else Reflect.deleteProperty(globalThis, 'window');
    if(previousStorage)Object.defineProperty(globalThis, 'localStorage', previousStorage);
    else Reflect.deleteProperty(globalThis, 'localStorage');
  });
}

test('small videos must still be transcoded, even when compression checkbox is off', async (t) => {
  let calls = 0;
  withDesktop(t, async (kind, name, bytes) => {
    calls++;
    assert.equal(kind, 'video');
    assert.equal(name, 'tiny.mp4');
    assert.equal(bytes.byteLength, 3);
    return {name:'tiny.mp4', bytes:new Uint8Array([4, 5, 6, 7, 8]).buffer};
  });
  const original = new File([new Uint8Array([1,2,3])], 'tiny.mp4', {type:'video/mp4'});
  const saved = await prepareForPlayers(original, 'video', () => {});
  assert.equal(calls, 1);
  assert.equal(saved.name, 'tiny.mp4');
  assert.equal(saved.size, 5, 'a larger compatible conversion must win over the original');
  assert.notEqual(saved, original);
});

test('video conversion errors block saving instead of silently importing unsupported original', async (t) => {
  withDesktop(t, async () => { throw new Error('FFmpeg failed'); });
  const original = new File(['invalid'], 'broken.mov', {type:'video/quicktime'});
  const messages: string[] = [];
  await assert.rejects(prepareForPlayers(original,'video',m=>messages.push(m)), /FFmpeg failed/);
  assert.ok(messages.some(m=>m.includes('Не удалось подготовить совместимое видео')));
});

test('empty conversion output blocks saving', async (t) => {
  withDesktop(t, async () => ({name:'video.mp4',bytes:new ArrayBuffer(0)}));
  const original = new File(['input'], 'video.mov', {type:'video/quicktime'});
  await assert.rejects(prepareForPlayers(original,'video',()=>{}), /не создал совместимый файл/);
});
