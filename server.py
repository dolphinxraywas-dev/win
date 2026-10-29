import os
import uuid
from functools import wraps
from flask import Flask, jsonify, request
from supabase import create_client, Client

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 6 * 1024 * 1024
SUPABASE_URL = os.environ.get("SUPABASE_URL", "").rstrip("/")
SUPABASE_ANON_KEY = os.environ.get("SUPABASE_ANON_KEY", "")
SUPABASE_SERVICE_ROLE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
HOST_ADMIN_EMAILS = {x.strip().lower() for x in os.environ.get("HOST_ADMIN_EMAILS", "").split(",") if x.strip()}
db: Client | None = None
if SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY:
    db = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

def api_error(message, status=400):
    return jsonify({"error": message}), status

def require_db(fn):
    @wraps(fn)
    def wrapped(*args, **kwargs):
        if db is None:
            return api_error("Backend is not configured. Set Supabase environment variables.", 503)
        return fn(*args, **kwargs)
    return wrapped

def require_user(fn):
    @wraps(fn)
    def wrapped(*args, **kwargs):
        if db is None:
            return api_error("Backend is not configured.", 503)
        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return api_error("Sign in required.", 401)
        try:
            user = db.auth.get_user(auth[7:]).user
            if not user:
                return api_error("Invalid session.", 401)
            request.user = user
        except Exception:
            return api_error("Invalid or expired session.", 401)
        return fn(*args, **kwargs)
    return wrapped

def require_host(fn):
    @wraps(fn)
    @require_user
    def wrapped(*args, **kwargs):
        email = (getattr(request.user, "email", "") or "").lower()
        if email not in HOST_ADMIN_EMAILS:
            return api_error("Host access denied.", 403)
        return fn(*args, **kwargs)
    return wrapped

@app.get("/health")
def health():
    return jsonify({"ok": True, "service": "nba-dice-api", "database_configured": db is not None})

@app.get("/api/me")
@require_user
def me():
    result = db.table("profiles").select("*").eq("id", request.user.id).maybe_single().execute()
    return jsonify({"profile": result.data})

@app.post("/api/profile")
@require_user
def create_profile():
    body = request.get_json(silent=True) or {}
    name = str(body.get("player_name", "")).strip()
    if not 1 <= len(name) <= 24:
        return api_error("Player name must be 1–24 characters.")
    existing = db.table("profiles").select("id").eq("id", request.user.id).maybe_single().execute()
    if existing.data:
        return api_error("Profile already exists.", 409)
    result = db.table("profiles").insert({"id": request.user.id, "player_name": name}).execute()
    return jsonify({"profile": result.data[0]}), 201

@app.get("/api/history")
@require_user
def history():
    result = db.table("game_history").select("id,pick_one,pick_two,dice,bet,matches,payout,created_at").eq("player_id", request.user.id).order("created_at", desc=True).limit(50).execute()
    return jsonify({"history": result.data})

@app.post("/api/roll")
@require_user
def roll():
    body = request.get_json(silent=True) or {}
    try:
        pick_one, pick_two, bet = int(body["pick_one"]), int(body["pick_two"]), int(body["bet"])
    except (KeyError, TypeError, ValueError):
        return api_error("Provide pick_one, pick_two and bet as integers.")
    if pick_one not in range(1, 7) or pick_two not in range(1, 7) or not 1 <= bet <= 1_000_000:
        return api_error("Invalid picks or bet.")
    result = db.rpc("play_game", {"p_player_id": request.user.id, "p_pick_one": pick_one, "p_pick_two": pick_two, "p_bet": bet}).execute()
    return jsonify(result.data)

@app.post("/api/payments")
@require_user
def submit_payment():
    body = request.get_json(silent=True) or {}
    kind = body.get("request_type")
    try:
        coins = int(body.get("coins", 0))
        amount = float(body.get("amount", 0))
    except (ValueError, TypeError):
        return api_error("Invalid coin amount or payment amount.")
    if kind not in ("buy", "exchange") or coins < 1 or amount < 0:
        return api_error("Invalid payment request.")
    row = {"player_id": request.user.id, "request_type": kind, "coins": coins, "amount": amount, "account_details": str(body.get("account_details", ""))[:500] or None}
    result = db.table("payment_requests").insert(row).execute()
    return jsonify({"request": result.data[0]}), 201

@app.post("/api/payments/<request_id>/screenshot")
@require_user
def upload_screenshot(request_id):
    upload = request.files.get("file")
    if not upload:
        return api_error("Choose a screenshot file.")
    if upload.mimetype not in ("image/jpeg", "image/png", "image/webp"):
        return api_error("Only JPG, PNG or WebP screenshots are accepted.")
    data = upload.read(5 * 1024 * 1024 + 1)
    if len(data) > 5 * 1024 * 1024:
        return api_error("Screenshot must be 5 MB or smaller.")
    found = db.table("payment_requests").select("id,player_id").eq("id", request_id).maybe_single().execute().data
    if not found or found["player_id"] != request.user.id:
        return api_error("Payment request not found.", 404)
    path = f'{request.user.id}/{request_id}/{uuid.uuid4().hex}'
    db.storage.from_("payment-screenshots").upload(path, data, {"content-type": upload.mimetype, "upsert": "false"})
    db.table("payment_requests").update({"screenshot_path": path}).eq("id", request_id).execute()
    return jsonify({"ok": True})

@app.get("/api/host/payments")
@require_host
def host_payments():
    rows = db.table("payment_requests").select("*,profiles(player_name)").eq("status", "pending").order("created_at").execute()
    output = []
    for row in rows.data:
        path = row.get("screenshot_path")
        if path:
            try:
                row["screenshot_url"] = db.storage.from_("payment-screenshots").create_signed_url(path, 300).get("signedURL")
            except Exception:
                row["screenshot_url"] = None
        output.append(row)
    return jsonify({"requests": output})

@app.post("/api/host/payments/<request_id>/review")
@require_host
def review_payment(request_id):
    body = request.get_json(silent=True) or {}
    status = body.get("status")
    if status not in ("approved", "rejected", "completed"):
        return api_error("Status must be approved, rejected or completed.")
    result = db.rpc("review_payment", {"p_request_id": request_id, "p_status": status, "p_reviewer": request.user.id}).execute()
    return jsonify(result.data)

@app.post("/api/host/coins")
@require_host
def adjust_coins():
    body = request.get_json(silent=True) or {}
    try:
        player_id, delta = str(body["player_id"]), int(body["delta"])
    except (KeyError, ValueError, TypeError):
        return api_error("Provide player_id and integer delta.")
    if not -1_000_000 <= delta <= 1_000_000 or delta == 0:
        return api_error("Invalid adjustment.")
    result = db.rpc("adjust_player_coins", {"p_player_id": player_id, "p_delta": delta, "p_reason": str(body.get("reason", "host adjustment"))[:120], "p_host_id": request.user.id}).execute()
    return jsonify(result.data)

@app.get("/api/groups")
@require_user
def groups():
    result = db.table("groups").select("id,name,invite_code,status,countdown_ends_at,created_at").eq("status", "open").order("created_at", desc=True).limit(100).execute()
    return jsonify({"groups": result.data})

@app.post("/api/groups")
@require_user
def create_group():
    body = request.get_json(silent=True) or {}
    name = str(body.get("name", "Lucky Room")).strip()[:60] or "Lucky Room"
    result = db.table("groups").insert({"name": name, "created_by": request.user.id}).execute()
    return jsonify({"group": result.data[0]}), 201

@app.get("/api/chat")
@require_user
def chat():
    result = db.table("chat_messages").select("id,player_id,group_id,message,created_at,profiles(player_name)").order("created_at", desc=True).limit(100).execute()
    return jsonify({"messages": list(reversed(result.data))})

@app.post("/api/chat")
@require_user
def post_chat():
    body = request.get_json(silent=True) or {}
    message = str(body.get("message", "")).strip()
    if not 1 <= len(message) <= 1000:
        return api_error("Message must be 1–1000 characters.")
    result = db.table("chat_messages").insert({"player_id": request.user.id, "message": message}).execute()
    return jsonify({"message": result.data[0]}), 201

@app.errorhandler(413)
def too_large(_):
    return api_error("Upload too large; maximum request size is 6 MB.", 413)

@app.errorhandler(Exception)
def unhandled(error):
    app.logger.exception("Unhandled API error: %s", error)
    return jsonify({"error": "Internal server error."}), 500
