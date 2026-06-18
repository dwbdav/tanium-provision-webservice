import os
import re
import time
import secrets
import logging
import threading
from logging.handlers import RotatingFileHandler
from urllib.parse import urlparse
from flask import Flask, request, redirect, url_for, session, abort
from werkzeug.exceptions import HTTPException
from werkzeug.middleware.proxy_fix import ProxyFix
from core import (
    ensure_db, ensure_logs_db, guard, ensure_users_schema,
    authenticate, update_last_login, set_user_password,
    render_inline,
    PUBLIC_API_PATHS, PUBLIC_API_PREFIXES, STATIC_PREFIXES,
    ensure_networks_schema, is_ip_allowed, record_network_seen, is_network_gated_path,
    ensure_config_schema,
)

_CSRF_SAFE_METHODS = {"GET", "HEAD", "OPTIONS", "TRACE"}


def _csrf_exempt_path(path: str) -> bool:
    """Device/machine APIs and static assets authenticate per-request
    (no session cookie) and must not be subject to CSRF checks."""
    p = path or "/"
    p_noslash = p.rstrip("/") or "/"
    if p in PUBLIC_API_PATHS or p_noslash in PUBLIC_API_PATHS:
        return True
    if any(p.startswith(pref) for pref in PUBLIC_API_PREFIXES):
        return True
    if any(p.startswith(pref) for pref in STATIC_PREFIXES):
        return True
    return False


def _same_site_origin(value: str) -> bool:
    """True if the Origin/Referer header points at this same host."""
    try:
        parsed = urlparse(value)
    except Exception:
        return False
    if not parsed.netloc:
        return False
    return parsed.netloc == request.host


# --- Login brute-force throttling (in-memory, per source IP) ---
# Keyed on the source IP only (never on the account), so an attacker can only
# lock out their own IP, never your admin account. In-memory: fits the single
# -process deployment; counters reset on restart. With multiple workers the
# effective limit is multiplied by the worker count.
LOGIN_MAX_ATTEMPTS = 5
LOGIN_LOCKOUT_SECONDS = 15 * 60
_login_attempts = {}            # ip -> list[timestamps of recent failures]
_login_attempts_lock = threading.Lock()


def _login_retry_after(ip: str) -> int:
    """Remaining lockout seconds for this IP (0 if not locked)."""
    now = time.time()
    with _login_attempts_lock:
        fails = [t for t in _login_attempts.get(ip, []) if now - t < LOGIN_LOCKOUT_SECONDS]
        if fails:
            _login_attempts[ip] = fails
        else:
            _login_attempts.pop(ip, None)
        if len(fails) >= LOGIN_MAX_ATTEMPTS:
            return max(1, int(LOGIN_LOCKOUT_SECONDS - (now - min(fails))))
        return 0


def _login_record_failure(ip: str) -> None:
    now = time.time()
    with _login_attempts_lock:
        fails = [t for t in _login_attempts.get(ip, []) if now - t < LOGIN_LOCKOUT_SECONDS]
        fails.append(now)
        _login_attempts[ip] = fails


def _login_reset(ip: str) -> None:
    with _login_attempts_lock:
        _login_attempts.pop(ip, None)


END_PROVISION_RE = re.compile(
    r"^\s*(?:\[(?:INFO|OK|WARN|ERROR|SKIP)\]\s*)?END\s*PROVISION(?:ING|NING)?\s*$",
    re.IGNORECASE,
)
RUNNING_HOOK_RE = re.compile(
    r"running\s+endprovisionning\.ps1\b.*waiting\s+for\s+completion",
    re.IGNORECASE,
)
PROFILE_RE = re.compile(r"Customer\s*-\s*\[([A-Za-z0-9_-]+)\]")

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
LOCAL_LOGS_DIR = os.path.join(BASE_DIR, "logs")
RUNTIME_LOG_NAME = "webservice-runtime.log"
RUNTIME_LOG_MAX_BYTES = 10 * 1024 * 1024
RUNTIME_LOG_BACKUP_COUNT = 10
SECRET_KEY_FILE = os.path.join(BASE_DIR, ".secret_key")


def _env_flag(name: str, default: bool = False) -> bool:
    raw = (os.environ.get(name) or "").strip().lower()
    if not raw:
        return default
    return raw in ("1", "true", "yes", "on")


def _load_or_create_secret_key() -> str:
    """Return the Flask SECRET_KEY.

    Resolution order: WS_SECRET_KEY env var, then the persisted key file, then
    generate and persist a new key on first run. The key file is created with
    mode 0600 (owner read/write only). Never commit this file.
    """
    env_key = (os.environ.get("WS_SECRET_KEY") or "").strip()
    if len(env_key) >= 32:
        return env_key

    # Use the existing key file if present and valid.
    try:
        with open(SECRET_KEY_FILE, "r", encoding="utf-8") as fh:
            key = fh.read().strip()
        if len(key) >= 32:
            return key
    except FileNotFoundError:
        pass

    # First run: generate a key and persist it atomically (mode 0600).
    new_key = secrets.token_urlsafe(48)
    try:
        with open(SECRET_KEY_FILE, "x", encoding="utf-8") as fh:
            fh.write(new_key + "\n")
        try:
            os.chmod(SECRET_KEY_FILE, 0o600)
        except OSError:
            pass
        return new_key
    except FileExistsError:
        # Another worker created it first; read theirs so all workers agree.
        with open(SECRET_KEY_FILE, "r", encoding="utf-8") as fh:
            key = fh.read().strip()
        if len(key) < 32:
            raise RuntimeError("SECRET_KEY file is invalid.")
        return key


def _attach_rotating_file_handler(logger: logging.Logger, handler: RotatingFileHandler) -> None:
    target = os.path.abspath(getattr(handler, "baseFilename", ""))
    for existing in logger.handlers:
        existing_path = os.path.abspath(getattr(existing, "baseFilename", ""))
        if existing_path and existing_path == target:
            return
    logger.addHandler(handler)


def _create_runtime_file_handler() -> RotatingFileHandler:
    env_path = (os.environ.get("WS_RUNTIME_LOG_PATH") or "").strip()
    path = env_path or os.path.join(LOCAL_LOGS_DIR, RUNTIME_LOG_NAME)
    folder = os.path.dirname(path)
    if folder:
        os.makedirs(folder, exist_ok=True)
    return RotatingFileHandler(
        path,
        maxBytes=RUNTIME_LOG_MAX_BYTES,
        backupCount=RUNTIME_LOG_BACKUP_COUNT,
        encoding="utf-8",
    )


def _configure_runtime_file_logging(app: Flask) -> None:
    root_logger = logging.getLogger()
    if getattr(root_logger, "_ws_runtime_file_configured", False):
        return

    file_handler = _create_runtime_file_handler()
    file_handler.setLevel(logging.INFO)
    file_handler.setFormatter(logging.Formatter(
        "%(asctime)s %(levelname)s %(name)s - %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    ))

    # Capture runtime messages from Flask app and Werkzeug HTTP access logs.
    _attach_rotating_file_handler(root_logger, file_handler)
    _attach_rotating_file_handler(app.logger, file_handler)
    _attach_rotating_file_handler(logging.getLogger("werkzeug"), file_handler)

    if app.logger.level == logging.NOTSET or app.logger.level > logging.INFO:
        app.logger.setLevel(logging.INFO)
    wz_logger = logging.getLogger("werkzeug")
    if wz_logger.level == logging.NOTSET or wz_logger.level > logging.INFO:
        wz_logger.setLevel(logging.INFO)

    root_logger._ws_runtime_file_configured = True


def create_app():
    app = Flask(__name__)
    _configure_runtime_file_logging(app)
    app.wsgi_app = ProxyFix(
        app.wsgi_app,
        x_for=1,
        x_proto=1,
        x_host=1,
        x_prefix=1,
    )

    # --- config
    app.config["SECRET_KEY"] = _load_or_create_secret_key()
    app.config.update(
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Strict",
        # Secure cookies require HTTPS at the browser-facing endpoint (the proxy).
        # If you reach the app over plain HTTP, start it with WS_COOKIE_SECURE=0.
        SESSION_COOKIE_SECURE=_env_flag("WS_COOKIE_SECURE", default=True),
    )

    # -------------------------------
    # Error page (better 400 messages)
    # -------------------------------
    def _render_error(err):
        code = getattr(err, "code", 500)
        name = err.name if isinstance(err, HTTPException) else "Server Error"
        desc = err.description if isinstance(err, HTTPException) else "Unexpected error."
        back_url = request.referrer or url_for("home")
        extra = ""
        if desc == "type in use":
            extra = "This type is still assigned to machines. Update those machines first, then try again."

        tmpl = r"""
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8"/>
  <title>{{ code }} {{ name }}</title>
__HEAD_ASSETS__
  <style>
    :root{
      --bg:#0b1220; --panel:#121a2b; --text:#e6edf3; --muted:#8fa1b3;
      --border:rgba(255,255,255,.06); --heading:#dbe8ff;
    }
    body{background:var(--bg); color:var(--text)}
    .card{background:var(--panel); border:1px solid var(--border)}
    h1{color:var(--heading)!important}
    .lead{color:var(--muted)}
  </style>
</head>
<body class="p-4">
  <div class="container-fluid">
    <div class="card shadow-sm p-4">
      <h1 class="mb-2">{{ code }} {{ name }}</h1>
      <p class="lead mb-3">{{ desc }}</p>
      {% if extra %}<p class="mb-3">{{ extra }}</p>{% endif %}
      <div class="d-flex gap-2">
        <a class="btn btn-primary" href="{{ back_url }}">Back</a>
        <a class="btn btn-secondary" href="{{ url_for('home') }}">Home</a>
      </div>
    </div>
  </div>
</body>
</html>
        """
        return render_inline(tmpl, code=code, name=name, desc=desc, extra=extra, back_url=back_url), code
    @app.errorhandler(400)
    def bad_request(err):
        return _render_error(err)

    @app.before_request
    def _guard():
        return guard()

    @app.before_request
    def _csrf_protect():
        """Origin-based CSRF protection for state-changing requests.

        Cookie-authenticated GUI requests (login, password change, all CRUD and
        file actions) must originate from this same host. Device/machine APIs
        authenticate per-request without a cookie and are exempt. Combined with
        SameSite=Strict cookies this blocks cross-site request forgery without
        touching the inline form templates.
        """
        if request.method in _CSRF_SAFE_METHODS:
            return None
        if _csrf_exempt_path(request.path):
            return None

        origin = request.headers.get("Origin")
        if origin:
            if not _same_site_origin(origin):
                abort(400, "CSRF check failed: cross-origin request blocked.")
            return None

        referer = request.headers.get("Referer")
        if referer:
            if not _same_site_origin(referer):
                abort(400, "CSRF check failed: cross-origin request blocked.")
            return None

        abort(400, "CSRF check failed: missing Origin/Referer header.")

    @app.before_request
    def _network_guard():
        """Option A — network restriction.

        Block the machine-facing surface (device/Tanium APIs + the file
        repository) for any source IP that is not inside an Allowed network.
        The admin GUI, login and static assets are never gated, so an admin can
        always connect and unblock a network. A newly seen network is recorded
        as Blocked on first sighting.
        """
        if not is_network_gated_path(request.path):
            return None
        ip = request.remote_addr or ""
        if is_ip_allowed(ip):
            return None
        try:
            record_network_seen(ip)
        except Exception:
            pass
        abort(403, "Network not allowed.")

    # -------------------------------
    # AUTH (GUI) — username/password (password can be empty)
    # -------------------------------
    @app.route("/login", methods=["GET", "POST"])
    def login():
        error = None
        if request.method == "POST":
          ip = request.remote_addr or "unknown"
          wait = _login_retry_after(ip)
          if wait > 0:
            mins = max(1, (wait + 59) // 60)
            error = "Too many failed attempts. Try again in %d minute(s)." % mins
          else:
            user = request.form["username"].strip()
            pwd  = request.form["password"]
            urow = authenticate(user, pwd)
            if not urow:
              _login_record_failure(ip)
              error = "Invalid credentials."
            else:
              _login_reset(ip)
              session["username"] = urow["username"]
              session["role"] = "admin"
              session["auth_ok"] = True
              update_last_login(urow["username"])
              nxt = request.args.get("next")
              # Only allow internal paths. Reject protocol-relative ("//host")
              # and backslash ("/\host") forms that browsers treat as external,
              # to prevent open-redirect abuse after login.
              if (not nxt
                      or not nxt.startswith("/")
                      or nxt.startswith("//")
                      or nxt.startswith("/\\")):
                nxt = url_for("home")
              return redirect(nxt)

        tmpl = r"""
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8"/>
            <title>Sign in</title>
__HEAD_ASSETS__
        </head>
        <body class="bg-light d-flex align-items-center" style="min-height:100vh;">
          <div class="container-fluid">
            <div class="row justify-content-center">
              <div class="col-12" style="max-width:440px;">
                <div class="card shadow-sm border-0">
                  <div class="card-body">
                    <h1 class="h4 mb-3 fw-bold">Sign in</h1>
                    {% if error %}
                      <div class="alert alert-danger py-2">{{ error }}</div>
                    {% endif %}
                    <form method="post">
                      <div class="mb-3">
                        <label class="form-label fw-semibold">Username</label>
                        <input type="text" name="username" class="form-control" required autofocus placeholder="account">
                      </div>
                      <div class="mb-3">
                        <label class="form-label fw-semibold">Password</label>
                        <input type="password" name="password" class="form-control" placeholder="(leave empty if none)">
                      </div>
                      <button class="btn btn-primary w-100" type="submit">Enter</button>
                    </form>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </body>
        </html>
        """
        return render_inline(tmpl, error=error)

    @app.route("/logout", methods=["GET", "POST"])
    def logout():
        session.clear()
        return redirect(url_for("login"))

    # -------------------------------
    # ACCOUNT — dedicated change-password page (self-service)
    # -------------------------------
    @app.route("/account/password", methods=["GET", "POST"])
    def account_password():

        uname = session.get("username") or ""
        err = None
        if request.method == "POST":
          p1 = request.form["password"]
          p2 = request.form["password2"]
          if len(p1) < 8:
            err = "Password must be at least 8 characters."
          elif p1 != p2:
            err = "Passwords do not match."
          else:
            set_user_password(uname, p1)
            return redirect(url_for("home"))

        tmpl = r"""
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8"/>
  <title>Change password</title>
__HEAD_ASSETS__
  <style>
    :root{ --bg:#0b1220; --panel:#121a2b; --text:#e6edf3; --muted:#8fa1b3; --border:rgba(255,255,255,.06); --heading:#dbe8ff; }
    body{background:var(--bg); color:var(--text)}
    .card{background:var(--panel); border:1px solid var(--border)}
    h1,.form-label{color:var(--heading)!important}
    .form-control{background:#0f1726!important; color:var(--text)!important; border:1px solid var(--border)!important; caret-color:var(--text)}
    .form-control::placeholder{color:var(--muted); opacity:1}
    .form-control:focus{border-color:#29406b!important; box-shadow:0 0 0 .2rem rgba(103,179,255,.15)!important}
  </style>
</head>
<body class="p-4">
  <div class="container-fluid">
    <div class="mb-3">
      <h1 class="mb-0">Change password</h1>
    </div>

    {% if err %}<div class="alert alert-danger">{{ err }}</div>{% endif %}

    <form method="post" class="card shadow-sm p-3">
      <div class="row g-3">
        <div class="col-md-6">
          <label class="form-label">New password</label>
          <input id="password" name="password" type="password" class="form-control" placeholder="≥ 8 chars" required>
        </div>
        <div class="col-md-6">
          <label class="form-label">Confirm</label>
          <input id="password2" name="password2" type="password" class="form-control" placeholder="Confirm" required>
        </div>
      </div>
      <div class="mt-4">
        <button class="btn btn-primary" type="submit">Save</button>
        <a class="btn btn-secondary" href="{{ url_for('home') }}">Cancel</a>
      </div>
    </form>
  </div>

  <script>
    (function(){
      const f = document.forms[0];
      f.addEventListener('submit', function(ev){
        const p1 = document.getElementById('password').value || '';
        const p2 = document.getElementById('password2').value || '';
        if (p1.length < 8){ alert('Password must be at least 8 characters'); ev.preventDefault(); return; }
        if (p1 !== p2){ alert('Passwords do not match'); ev.preventDefault(); return; }
      });
    })();
  </script>
</body>
</html>
        """
        return render_inline(tmpl, err=err)

    # -------------------------------
    # -------------------------------
    # HOME - default landing redirects to Computers
    # -------------------------------
    @app.route("/")
    def home():
        return redirect(url_for("computers.computers_list"))

    from bp_gui       import apps_bp, computers_bp, configs_bp, drivers_bp, progress_bp, types_bp, users_bp
    from bp_api_php   import bp as api_php_bp
    from bp_files     import bp as files_bp
    from bp_network   import bp as network_bp

    app.register_blueprint(computers_bp)
    app.register_blueprint(drivers_bp)
    app.register_blueprint(apps_bp)
    app.register_blueprint(configs_bp)
    app.register_blueprint(types_bp)
    app.register_blueprint(progress_bp)
    app.register_blueprint(api_php_bp)
    app.register_blueprint(files_bp)
    app.register_blueprint(users_bp)
    app.register_blueprint(network_bp)

    # --- DB init (includes users schema)
    ensure_db()
    ensure_logs_db()
    ensure_users_schema()
    ensure_networks_schema()
    ensure_config_schema()

    return app

if __name__ == "__main__":
    app = create_app()
    # SECURITY: the Werkzeug interactive debugger allows remote code execution
    # on any unhandled exception. It stays OFF by default and must be opted into
    # explicitly (WS_DEBUG=1) for LOCAL development only — never on a reachable
    # host. The auto-reloader is now independent of the debugger.
    debug = _env_flag("WS_DEBUG", default=False)
    auto_reload = _env_flag("WS_AUTO_RELOAD", default=False)
    app.run(
        host=os.environ.get("WS_BIND_HOST", "0.0.0.0"),
        port=int(os.environ.get("WS_PORT", "12176")),
        debug=debug,
        use_reloader=auto_reload,
        threaded=True,
    )
