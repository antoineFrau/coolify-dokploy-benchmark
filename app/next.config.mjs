/** @type {import('next').NextConfig} */
export default {
  // Standalone output keeps the runtime image small, which matters for the §13 disk test.
  output: "standalone",
  eslint: { ignoreDuringBuilds: true },
};
