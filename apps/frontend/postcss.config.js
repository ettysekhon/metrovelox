// PostCSS config required by Next.js to run Tailwind's JIT compiler over
// `app/globals.css`. Without this file Next treats the CSS as a pure
// passthrough: the `@tailwind base/components/utilities` directives ship
// to the browser untouched and every `className` utility silently
// no-ops, so the dashboard renders as unstyled HTML.
module.exports = {
  plugins: {
    tailwindcss: {},
    autoprefixer: {},
  },
};
