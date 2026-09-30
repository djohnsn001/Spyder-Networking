#!/usr/bin/env node

/**
 * Removes hidden photo data (EXIF / XMP: GPS location, camera, time taken)
 * from avatar files uploaded before security item M3. Since M3 the app
 * re-encodes every new photo, which drops that data; older uploads were the
 * original file as picked, and the avatars bucket is public.
 *
 * For every file in the avatars bucket:
 *   - reads its metadata; files without EXIF/XMP are left alone;
 *   - otherwise re-saves it in the same format (JPEG / PNG / WebP) at the
 *     same path, turned upright first, with all metadata dropped, so every
 *     profile's avatar_url keeps working;
 *   - formats it can't re-save (e.g. HEIC) are listed for a manual look.
 *
 * Needs .env.seed.local (SUPABASE_URL + SUPABASE_SECRET_KEY), never .env;
 * see scripts/seed-env.js. Refuses to run against production
 * (fhevoocpcnrjxyjvitai) unless --i-know-this-is-production is passed, which
 * is the point of this script once it has been tried on dev.
 *
 * Usage:
 *   node scripts/clean-avatar-exif.js                  # dry run: lists what it would clean
 *   node scripts/clean-avatar-exif.js --apply          # actually re-saves the files
 */

const sharp = require("sharp");
const { createAdminClient, loadSeedEnv } = require("./seed-env");

const AVATAR_BUCKET = "avatars";
const PAGE_SIZE = 100;
const REWRITABLE = {
  jpeg: { contentType: "image/jpeg", encode: (img) => img.jpeg({ quality: 85, mozjpeg: true }) },
  png: { contentType: "image/png", encode: (img) => img.png() },
  webp: { contentType: "image/webp", encode: (img) => img.webp({ quality: 85 }) },
};

// Every entry in one folder ('' = the bucket root), page by page.
async function listAll(supabase, folder) {
  const entries = [];
  for (let offset = 0; ; offset += PAGE_SIZE) {
    const { data, error } = await supabase.storage
      .from(AVATAR_BUCKET)
      .list(folder, { limit: PAGE_SIZE, offset, sortBy: { column: "name", order: "asc" } });
    if (error) throw error;
    entries.push(...data);
    if (data.length < PAGE_SIZE) break;
  }
  return entries;
}

// Every file path in the bucket. Avatars live one level deep: <user id>/<file>.
async function listAvatarFiles(supabase) {
  const paths = [];
  for (const entry of await listAll(supabase, "")) {
    // Folders come back with id null.
    if (entry.id) {
      paths.push(entry.name);
      continue;
    }
    for (const file of await listAll(supabase, entry.name)) {
      if (file.id) paths.push(`${entry.name}/${file.name}`);
    }
  }
  return paths;
}

async function main() {
  // Reads .env.seed.local and exits unless the target is safe (see seed-env.js).
  const { url, serviceKey } = loadSeedEnv();
  const apply = process.argv.includes("--apply");
  const supabase = createAdminClient({ url, serviceKey });

  const paths = await listAvatarFiles(supabase);
  console.log(`${paths.length} avatar file(s) found.${apply ? "" : " (dry run: nothing is changed)"}`);

  const counts = { clean: 0, cleaned: 0, manual: 0, failed: 0 };
  for (const path of paths) {
    try {
      const { data: blob, error } = await supabase.storage.from(AVATAR_BUCKET).download(path);
      if (error) throw error;
      const input = Buffer.from(await blob.arrayBuffer());

      let meta;
      try {
        meta = await sharp(input).metadata();
      } catch {
        meta = null;
      }
      const format = meta?.format;
      const hasMetadata = Boolean(meta?.exif || meta?.xmp || meta?.iptc);

      if (meta && !hasMetadata) {
        counts.clean++;
        continue;
      }
      const target = REWRITABLE[format];
      if (!target) {
        counts.manual++;
        console.log(`  MANUAL  ${path} (${format ?? "unreadable"}: can't re-save this format; download and check it)`);
        continue;
      }

      if (!apply) {
        counts.cleaned++;
        console.log(`  WOULD CLEAN  ${path} (${format}${meta.exif ? ", EXIF" : ""}${meta.xmp ? ", XMP" : ""})`);
        continue;
      }

      // rotate() with no angle applies the EXIF orientation, so the photo
      // stays upright once that tag is gone. sharp drops all metadata unless
      // asked to keep it.
      const output = await target.encode(sharp(input).rotate()).toBuffer();
      const check = await sharp(output).metadata();
      if (check.exif || check.xmp || check.iptc) throw new Error("metadata still present after re-encoding");

      const { error: uploadError } = await supabase.storage
        .from(AVATAR_BUCKET)
        .upload(path, output, { contentType: target.contentType, upsert: true, cacheControl: "3600" });
      if (uploadError) throw uploadError;
      counts.cleaned++;
      console.log(`  CLEANED  ${path} (${input.length} -> ${output.length} bytes)`);
    } catch (error) {
      counts.failed++;
      console.error(`  FAILED  ${path}: ${error.message ?? error}`);
    }
  }

  console.log(
    `\nDone. Already clean: ${counts.clean}. ${apply ? "Cleaned" : "Would clean"}: ${counts.cleaned}. ` +
      `Manual: ${counts.manual}. Failed: ${counts.failed}.`
  );
  if (!apply && counts.cleaned > 0) console.log("Run again with --apply to clean them.");
  if (counts.failed > 0) process.exitCode = 1;
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
