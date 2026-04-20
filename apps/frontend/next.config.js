/** @type {import('next').NextConfig} */
module.exports = {
  // Required by apps/frontend/Dockerfile: produces .next/standalone with
  // a minimal node_modules closure so the runtime image can be built
  // without the full dev dependency tree.
  output: "standalone",
  // `experimental.ppr` requires the Next.js canary channel. We ship on
  // the stable release so enabling PPR breaks `next build`. Re-enable
  // here once the canary floor lines up with our dependency set.
};
