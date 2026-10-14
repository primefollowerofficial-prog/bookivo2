# BOOKIVO

Bookivo is a React, TypeScript, and Vite digital bookstore connected to Supabase. The repository includes the local database migration and Edge Functions for Cashfree checkout, verified payment fulfilment, private ebook downloads, and optional Brevo order email.

## Run locally

```sh
pnpm install
cp .env.example .env.local  # fill in the Supabase URL and publishable key
pnpm dev
```

Build with `pnpm build`. `.env.local` is ignored by Git. The browser build uses only the Supabase URL and publishable key; payment, service-role, and email credentials belong in Supabase Edge Function secrets.

## Backend setup

See [BACKEND_SETUP.md](./BACKEND_SETUP.md) for local Supabase setup, migration/function deployment commands, Auth redirects, Cashfree/Brevo secrets, RLS checks, and the production content checklist. The hosted Supabase project has not been changed by this work.

The migration seeds categories only. No source cookbook ebook, cover, or gallery assets were present in the workspace, so no sample title or downloadable file is seeded. Add only approved content using the admin catalogue.

## GitHub Pages

The workflow publishes the Vite app to the existing `bookivo.in` Pages site. Set `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` as GitHub Actions variables before publishing. GitHub Pages hosts the frontend only; Supabase serves the database and Edge Functions.
