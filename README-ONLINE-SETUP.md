# NBA DICE — online backend setup

This repository keeps the existing `index.html` game. The backend scaffold adds a Flask API, Supabase schema/functions, and Render deployment configuration. **The existing browser game is not yet connected to this API**, so do not treat shared balances, login, screenshots, host tools, or 24/7 hosting as live until the steps below and frontend integration are completed.

## 1. Create Supabase

1. Create a project at https://supabase.com/dashboard and save the database password privately.
2. Open **SQL Editor** and run `supabase/schema.sql`.
3. Then run `supabase/functions.sql`.
4. In **Project Settings → API**, copy the Project URL, anon/public key, and service-role key.
5. Keep the service-role key private. Never paste it into `index.html`, commit it to GitHub, or send it in chat.
6. Enable Email authentication in **Authentication → Providers**. Configure sign-up and email verification settings to suit your users.

The database uses a private `payment-screenshots` Storage bucket. The backend creates short-lived signed URLs for host review.

## 2. Deploy the backend to Render

1. Create an account at https://dashboard.render.com/register.
2. Choose **New → Blueprint** and connect this repository, or create a Python web service from it.
3. Use `render.yaml` / `requirements.txt`. The start command is `gunicorn server:app --bind 0.0.0.0:$PORT --workers 2 --threads 4 --timeout 120`.
4. In the service's Environment settings, add:
   - `SUPABASE_URL` — Supabase project URL
   - `SUPABASE_ANON_KEY` — public anon key (server-side use only here)
   - `SUPABASE_SERVICE_ROLE_KEY` — private service-role key
   - `HOST_ADMIN_EMAILS` — your verified sign-in email, comma-separated if multiple hosts
5. Use a paid always-on instance if you need to avoid free-tier sleeping. No hosting provider can promise zero downtime.
6. After deploy, open `https://YOUR-RENDER-SERVICE.onrender.com/health`. It should return `ok: true` and `database_configured: true`.

## 3. Publish the website

In GitHub, open **Settings → Pages**, choose **Deploy from a branch**, select `main` and `/(root)`, and save. The expected URL is https://dolphinxraywas-dev.github.io/win/ if Pages is enabled for this repository.

## 4. Required remaining integration

The current `index.html` still runs the original local-only game logic. Before inviting players, the frontend must be updated to:
- Add Supabase Auth sign-up/sign-in and require a valid session.
- Call `POST /api/profile` and `GET /api/me` rather than keeping balances in browser memory.
- Replace browser-side dice payout with `POST /api/roll`; the server function locks and updates the balance in a database transaction.
- Upload payment screenshots to `POST /api/payments/<request_id>/screenshot` after creating a payment request.
- Connect the host panel to `GET /api/host/payments`, `POST /api/host/payments/<id>/review`, and `POST /api/host/coins`.
- Connect groups and chat to the API; add real-time subscriptions or polling if live updates are needed.
- Ensure host controls are based on server-side identity, not a passcode embedded in JavaScript.

All authenticated API requests require `Authorization: Bearer <Supabase access token>`. Do not make the service-role key available to the browser.

## API endpoints currently scaffolded

- `GET /health`
- `GET /api/me`, `POST /api/profile`, `GET /api/history`
- `POST /api/roll`
- `POST /api/payments`, `POST /api/payments/<id>/screenshot`
- `GET /api/host/payments`, `POST /api/host/payments/<id>/review`, `POST /api/host/coins`
- `GET /api/groups`, `POST /api/groups`
- `GET /api/chat`, `POST /api/chat`

## Important safety notes

- The current frontend's old host/group passcode is not secure authentication. Do not rely on it for real money or balances.
- Payment approval and coin crediting are administrative actions; test with nonvaluable test accounts first.
- The API scaffold needs integration testing and security review before production use. The database RPC uses PostgreSQL's random function for dice outcomes; it is not a cryptographic gambling RNG.
