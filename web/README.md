# FocusFlow website

The landing page is a React app built with Bun and Vite. It builds into `docs/`,
which Vercel serves at `https://macflow-delta.vercel.app/`. The existing
`docs/studio/` recorder stays in place during builds.

```sh
bun install --frozen-lockfile
bun run dev
bun run build
```

The site uses the native app's current public features for its copy. The product
window and feature demonstrations are illustrations of the editor workflow.
