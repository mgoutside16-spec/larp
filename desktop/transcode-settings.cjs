// Baseline H.264 / AAC-LC, SDR 8-bit and at most 720p30 for older Android phones.
// Keep portrait orientation, and bound macroblocks/frame to H.264 Level 3.1.
// Compatibility takes priority over output size (the workshop must not keep HEVC).
const videoArgs = (input, output) => [
  '-hide_banner', '-y', '-xerror', '-i', input,
  '-map', '0:v:0', '-map', '0:a:0?',
  '-vf', "scale=w='if(gte(iw,ih),1280,720)':h='if(gte(iw,ih),720,1280)':force_original_aspect_ratio=decrease:force_divisible_by=2,fps=30",
  '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '24',
  '-profile:v', 'baseline', '-level:v', '3.1', '-bf', '0', '-refs', '1',
  '-pix_fmt', 'yuv420p', '-maxrate', '3M', '-bufsize', '6M',
  '-c:a', 'aac', '-profile:a', 'aac_low', '-b:a', '128k', '-ar', '44100', '-ac', '2',
  '-movflags', '+faststart', '-map_metadata', '-1',
  output,
];
const audioArgs = (input, output) => [
  '-hide_banner', '-y', '-i', input, '-vn',
  '-c:a', 'aac', '-b:a', '128k', '-map_metadata', '-1',
  output,
];


module.exports = {videoArgs, audioArgs};
