import sharp from "sharp";

export async function renderSvgToRgba(svg: string, size: number): Promise<Buffer> {
  return sharp(Buffer.from(svg))
    .resize(size, size)
    .ensureAlpha()
    .raw()
    .toColourspace("srgb")
    .toBuffer();
}
