"""
=============================================================================
bp_files.py - File & Log Management Blueprint
=============================================================================

Handles static file serving, log uploads, and device log storage.

Features:
  - Serve deployment packages and configurations
  - Upload and organize deployment logs
  - Safe path resolution to prevent traversal attacks
  - Log listing and viewing
"""

from datetime import datetime
from pathlib import Path
from flask import (
    Blueprint, current_app,
    send_from_directory, abort, request, url_for, redirect
)
from core import render_inline

bp = Blueprint("files", __name__)


def _file_root() -> Path:
    """Get root directory for shared deployment files."""
    root = Path(current_app.root_path).resolve() / "file"
    root.mkdir(parents=True, exist_ok=True)
    return root


def _safe_resolve(rel: str) -> Path:
    """Safely resolve a relative path within file root (prevent traversal attacks)."""
    root = _file_root()
    candidate = (root / rel).resolve()
    if candidate == root:
        return candidate
    if root not in candidate.parents:
        abort(404)
    return candidate


def _external_base() -> str:
    """Build external URL base respecting proxy headers."""
    proto = request.headers.get("X-Forwarded-Proto") or request.scheme
    host = request.headers.get("X-Forwarded-Host") or request.host
    fwd_prefix = request.headers.get("X-Forwarded-Prefix") or ""
    if fwd_prefix and ":" in host and host.rsplit(":", 1)[1].isdigit():
        host = host.rsplit(":", 1)[0]
    return f"{proto}://{host}"

def _no_cache(resp):
    """Disable caching for GUI and downloads."""
    resp.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
    resp.headers["Pragma"] = "no-cache"
    resp.headers["Expires"] = "0"
    return resp


def _format_size(size):
    if size is None:
        return "—"
    n = float(size)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024.0 or unit == "TB":
            if unit == "B":
                return f"{int(n)} {unit}"
            return f"{n:.1f} {unit}"
        n /= 1024.0

@bp.route("/file-hub", methods=["GET"])
def files_home():
    tmpl = r"""
<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <title>File Hub</title>
__HEAD_ASSETS__
  <style>
    .hub-shell{max-width:1280px}
    .page-head{display:flex; justify-content:space-between; align-items:flex-start; gap:1rem; flex-wrap:wrap; margin-bottom:1.4rem}
    .toolbar{display:flex; align-items:center; gap:.6rem; flex-wrap:wrap}
    .chip{
      display:inline-flex; align-items:center; gap:.6rem;
      background:#fff; color:#2f445a; border:1px solid #d9e2ea;
      border-radius:8px; padding:.45rem .72rem; text-decoration:none;
      box-shadow:0 1px 2px rgba(0,0,0,.04);
    }
    .chip:hover{transform:translateY(-1px); border-color:#c8d4e0; box-shadow:0 2px 6px rgba(0,0,0,.08)}
    .modicon{
      width:36px; height:36px; border-radius:10px; display:inline-flex;
      align-items:center; justify-content:center;
      box-shadow:inset 0 0 0 1px rgba(0,0,0,.25), 0 2px 10px rgba(0,0,0,.25);
      background:#3fa7ff;
    }
    .modicon svg{width:22px; height:22px}
    .modicon svg *{stroke:#fff; stroke-width:2; fill:none; stroke-linecap:round; stroke-linejoin:round}
    .subtitle{color:#64748b}
    .hub-grid{display:grid; grid-template-columns:1fr; gap:1rem}
    .hub-card{
      background:#fff;
      border:1px solid #e2e8ef;
      border-radius:14px;
      box-shadow:0 6px 18px rgba(15,23,42,.06);
      padding:1.2rem;
      min-height:260px;
      display:flex;
      flex-direction:column;
      gap:.9rem;
    }
    .hub-icon{
      width:52px; height:52px; border-radius:14px; display:inline-flex;
      align-items:center; justify-content:center;
      box-shadow:inset 0 0 0 1px rgba(0,0,0,.08);
    }
    .hub-icon.files{background:#e8f1ff}
    .hub-icon svg{width:28px; height:28px}
    .hub-icon.files svg *{stroke:#1f6fd1; stroke-width:2; fill:none; stroke-linecap:round; stroke-linejoin:round}
    .hub-title{font-size:1.2rem; font-weight:700; color:#1f2937}
    .hub-text{color:#5b6b7c; line-height:1.5}
    .hub-list{margin:0; padding-left:1.1rem; color:#516173}
    .hub-actions{margin-top:auto; display:flex; gap:.7rem; flex-wrap:wrap}
    @media (max-width: 900px){
      .hub-grid{grid-template-columns:1fr}
    }
  </style>
</head>
<body class="p-4">
  <div class="container-fluid hub-shell">
    <div class="page-head">
      <div>
        <h1 class="mb-1">File Hub</h1>
                    <div class="subtitle">Browse and manage deployment files.</div>
      </div>
      <div class="toolbar">
        <a class="chip" href="{{ url_for('home') }}">
          <span class="modicon">
            <svg viewBox="0 0 24 24"><path d="M3 10l9-7 9 7"/><path d="M5 10v10h5v-6h4v6h5V10"/></svg>
          </span>
          <span>Dashboard</span>
        </a>
      </div>
    </div>

    <div class="hub-grid">
      <section class="hub-card">
        <span class="hub-icon files">
          <svg viewBox="0 0 24 24"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>
        </span>
        <div class="hub-title">File Downloads</div>
        <div class="hub-text">Browse the shared repository, upload deployment files, create folders, and download packages.</div>
        <ul class="hub-list">
          <li>Provision scripts</li>
          <li>Drivers, bundles, packages</li>
          <li>Direct download links</li>
        </ul>
        <div class="hub-actions">
          <a class="btn btn-primary" href="{{ url_for('files.list_dir') }}">Open File Browser</a>
        </div>
      </section>
        </div>
  </div>
</body>
</html>
"""
    resp = current_app.make_response(render_inline(tmpl))
    return _no_cache(resp)


# --------- LISTE / NAV: /file[/<subpath>]
@bp.route("/file/", defaults={"subpath": ""}, methods=["GET"])
@bp.route("/file/<path:subpath>", methods=["GET"])
def list_dir(subpath: str):
    base = _safe_resolve(subpath)
    root = _file_root()

    if not base.exists():
        abort(404)

    # mode sélection (picker=1 => utilisé depuis Apps Add/Edit)
    picker = request.values.get("picker") == "1"
    picker_target = (request.values.get("picker_target") or "file").strip().lower()
    folder_picker = picker and picker_target == "folder"

    # File Hub is READ-ONLY. All write actions (upload, new_folder, rename,
    # delete) have been removed: they were reachable without authentication
    # via POST and allowed tampering with the deployment repository served to
    # and executed by the endpoints. Browsing and downloading only.

    # Si on pointe directement un fichier, redirige vers le RAW
    if base.is_file():
        return _no_cache(redirect(url_for("files.raw_get", subpath=subpath), code=302))

    # Breadcrumbs
    picker_args = {"picker": "1", "picker_target": picker_target} if picker else {}
    crumbs = [("Files", url_for("files.list_dir", **picker_args))]
    acc = ""
    for part in Path(subpath).parts:
        acc = f"{acc}/{part}" if acc else part
        crumbs.append((part, url_for("files.list_dir", subpath=acc, **picker_args)))

    parent_href = None
    if Path(subpath).parts:
        parent_rel = "/".join(Path(subpath).parts[:-1])
        parent_href = url_for("files.list_dir", subpath=parent_rel, **picker_args)

    # Contenu du dossier
    entries = []
    for p in sorted(base.iterdir(), key=lambda x: (x.is_file(), x.name.lower())):
        stat = p.stat()
        rel = str(p.relative_to(root)).replace("\\", "/")
        public_url = url_for("files.list_dir", subpath=rel)
        raw_url = url_for("files.raw_get", subpath=rel)
        raw_full = _external_base() + raw_url
        public_full = _external_base() + public_url
        entries.append({
            "name": p.name,
            "is_dir": p.is_dir(),
            "size": stat.st_size if p.is_file() else None,
            "size_text": _format_size(stat.st_size if p.is_file() else None),
            "mtime": datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M:%S"),
            "mtime_short": datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M"),
            "href": url_for("files.list_dir", subpath=rel, **picker_args) if p.is_dir()
                    else public_url,
            "dl": None if p.is_dir() else raw_url + "?download=1",
            "public_url": public_url,
            "public_full": public_full,
            "raw_url": raw_url,
            "raw_full": raw_full,
        })

    msg = (request.args.get("msg") or "").strip()
    kind = (request.args.get("kind") or "info").strip().lower()
    alert_class = {
        "error": "danger",
        "warning": "warning",
        "success": "success",
        "info": "info",
    }.get(kind, "info")

    tmpl = r"""
<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <title>File Browser</title>
  <script src="https://cdn.tailwindcss.com"></script>
__HEAD_ASSETS__
  <style>
    :root{
      --bg:#f3f7fb;
      --panel:#ffffff;
      --text:#102a43;
      --muted:#64748b;
      --border:#d9e4ef;
      --heading:#0f2942;
      --hover:#f4f9fd;
      --upload:#2bb673;
      --folder:#4f7df3;
    }
    body{
      background:#f8fafc;
      color:var(--text);
      font-family:"Segoe UI",system-ui,-apple-system,BlinkMacSystemFont,sans-serif;
    }
    .page-breadcrumb-inline{display:none !important}
    .files-shell{max-width:100%}
    .picker-shell{max-width:none}
    .files-head{
      display:grid;
      grid-template-columns:minmax(220px,1fr) auto;
      align-items:center;
      gap:1rem;
      margin-bottom:1.5rem;
    }
    .head-left{
      min-width:0;
    }
    .page-kicker{
      margin:0;
      color:#94a3b8;
      font-size:.75rem;
      font-weight:700;
      letter-spacing:.22em;
      text-transform:uppercase;
    }
    .head-left h1{
      margin:.5rem 0 0;
      color:#020617!important;
      line-height:1.05;
      font-size:1.875rem;
      font-weight:800;
      letter-spacing:-.025em;
    }
    .toolbar{
      display:flex;
      align-items:center;
      justify-content:flex-end;
      gap:.75rem;
      flex-wrap:wrap;
    }
    .chip{
      display:inline-flex;
      align-items:center;
      gap:.6rem;
      background:#fff;
      color:#2f445a;
      border:1px solid #d9e2ea;
      border-radius:12px;
      padding:.5rem .75rem;
      text-decoration:none;
      box-shadow:0 1px 3px rgba(0,0,0,.07);
      transition:.15s ease;
    }
    .chip:hover{
      transform:translateY(-1px);
      border-color:#c8d4e0;
      box-shadow:0 4px 10px rgba(0,0,0,.1);
      text-decoration:none;
      color:#1e293b;
    }
    .chip.btn-primary-green:hover{
      color:#fff!important;
    }
    .files-head .btn-primary-green{
      display:inline-flex;
      align-items:center;
      justify-content:center;
      min-height:40px;
      padding:8px 16px;
      border-radius:4px;
      font-size:1rem;
      font-weight:700;
      line-height:1.2;
      box-shadow:none;
      gap:0;
    }
    .chip .label{position:relative; top:1px}
    .modicon{
      width:36px;
      height:36px;
      border-radius:10px;
      display:inline-flex;
      align-items:center;
      justify-content:center;
      background:#fff;
      border:1px solid #dbe3ec;
      box-shadow:inset 0 0 0 1px rgba(255,255,255,.5);
    }
    .modicon svg{width:22px; height:22px}
    .modicon svg *{stroke:#fff; stroke-width:2; fill:none; stroke-linecap:round; stroke-linejoin:round}
    .back-chip{
      width:38px;
      height:38px;
      padding:0;
      justify-content:center;
      border-radius:10px;
    }
    .back-chip svg{
      width:18px;
      height:18px;
      stroke:#4f6b82;
      stroke-width:2;
      fill:none;
      stroke-linecap:round;
      stroke-linejoin:round;
    }
    .chip-upload .modicon{
      background:var(--upload);
      border-color:var(--upload);
    }
    .chip-folder .modicon{
      background:var(--folder);
      border-color:var(--folder);
    }
    .chip-cancel .modicon{
      background:#94a3b8;
      border-color:#94a3b8;
    }
    .table-wrap{
      background:var(--panel);
      border:1px solid var(--border);
      border-radius:16px;
      box-shadow:0 8px 24px rgba(16,42,67,.06);
      overflow:visible;
    }
    .table-wrap .table-responsive{
      overflow:visible;
    }
    .files-table{
      margin:0;
      --bs-table-bg:transparent;
      color:var(--text);
    }
    .files-table > :not(caption) > * > *{
      padding:.72rem .65rem;
      border-top:1px solid #e8eef4;
      vertical-align:middle;
      background:transparent;
      text-align:left;
    }
    .files-table thead th{
      background:#f8f9fa!important;
      color:#2e4358!important;
      text-transform:none;
      letter-spacing:0;
      font-size:.86rem;
      font-weight:800;
      border-top:0;
      border-bottom:1px solid #dce5ee;
      font-family:"Segoe UI", Tahoma, Arial, sans-serif;
      text-align:left;
    }
    .files-table tbody tr{
      transition:background-color .15s ease;
    }
    .files-table tbody tr.file-row{
      cursor:pointer;
    }
    .files-table tbody tr:hover{
      background:var(--hover);
    }
    .files-table tbody tr.is-selecting{
      background:#e6f4ff;
      box-shadow:inset 0 0 0 1px rgba(59,130,246,.25);
    }
    .files-table tbody tr:hover .row-actions-inner{
      opacity:1;
      transform:translateX(0);
      pointer-events:auto;
    }
    .entry-link{
      display:flex;
      align-items:center;
      gap:.7rem;
      min-width:0;
      text-decoration:none;
      color:inherit;
    }
    .entry-link:hover{text-decoration:none; color:inherit}
    .entry-icon{
      width:18px;
      height:18px;
      flex:0 0 auto;
      color:#6d84a0;
    }
    .entry-icon svg{
      width:18px;
      height:18px;
      stroke:currentColor;
      stroke-width:1.8;
      fill:none;
      stroke-linecap:round;
      stroke-linejoin:round;
    }
    .folder-link .entry-icon{color:#d38d15}
    .file-link .entry-icon,
    .file-name .entry-icon{color:#4f6b82}
    .entry-name{
      font-family:"Roboto Mono","Consolas","Courier New",monospace;
      font-size:.93rem;
      color:#1e3348;
      white-space:nowrap;
      overflow:hidden;
      text-overflow:ellipsis;
    }
    .size-col{white-space:nowrap; color:#5f7387; font-size:.85rem}
    .mtime{
      color:#64748b;
      font-family:"Roboto Mono","Consolas","Courier New",monospace;
      font-size:.83rem;
      white-space:nowrap;
    }
    .actions-cell{text-align:left; width:76px}
    .row-actions-inner{
      display:inline-flex;
      align-items:center;
      gap:.35rem;
      transition:opacity .15s ease, transform .15s ease;
    }
    .row-actions-inner .action-menu-wrap{
      width:34px;
    }
    .files-table .action-menu-wrap.is-open .action-menu-dropdown{
      display:flex !important;
    }
    .files-table .action-menu-dropdown{
      min-width:160px;
    }
    .action-icon{
      display:inline-flex;
      align-items:center;
      justify-content:center;
      width:30px;
      height:30px;
      border-radius:8px;
      border:1px solid #d8e3ee;
      background:#fff;
      text-decoration:none;
      padding:0;
    }
    .action-icon svg{
      width:15px;
      height:15px;
      stroke:currentColor;
      stroke-width:2;
      fill:none;
      stroke-linecap:round;
      stroke-linejoin:round;
    }
    .action-download{color:#4d6882}
    .action-download:hover{background:#eef6ff; border-color:#aac4dd; color:#234866}
    .action-rename{color:#1f6fd1}
    .action-rename:hover{background:#edf4ff; border-color:#b8cff1; color:#1557ab}
    .action-delete{color:#dc3545}
    .action-delete:hover{background:#fff0f1; border-color:#f1c0c5; color:#b42332}
    .empty-state{
      padding:2.4rem 1rem;
      text-align:center;
      color:#6f8092;
    }
    .empty-illus{
      font-size:2.1rem;
      line-height:1;
      opacity:.6;
      margin-bottom:.35rem;
    }
    .empty-title{
      font-size:1.02rem;
      color:#3f556b;
      font-weight:600;
    }
    .picker-search{
      width:min(520px, 42vw);
      min-width:260px;
      border:1px solid var(--border);
      border-radius:12px;
      padding:.78rem 1rem;
      background:#fff;
      color:var(--text);
      box-shadow:0 1px 3px rgba(16,42,67,.05);
      outline:none;
    }
    .picker-search:focus{
      border-color:#7aaedf;
      box-shadow:0 0 0 .2rem rgba(63,167,255,.12);
    }
    .picker-empty-filter{
      display:none;
      padding:1.4rem 1rem;
      color:#6f8092;
      text-align:center;
      font-weight:600;
    }
    @media (max-width:900px){
      .files-head{grid-template-columns:1fr; align-items:stretch}
      .actions-right{width:100%}
      .actions-right .toolbar{justify-content:flex-start}
      .picker-search{width:100%; min-width:0}
      .row-actions-inner{
        opacity:1;
        transform:none;
        pointer-events:auto;
      }
    }
  </style>
</head>
<body class="{% if picker %}p-3 picker-body{% else %}min-h-screen bg-slate-50 text-slate-900{% endif %}">
  <div class="container-fluid files-shell{% if picker %} picker-shell{% endif %}">
    {% if not picker %}<main class="mx-auto max-w-[1800px] px-8 py-8">{% endif %}
    <div class="files-head">
      <div class="head-left">
        {% if parent_href %}
          <a class="chip back-chip" href="{{ parent_href }}" title="Back" aria-label="Back">
            <svg viewBox="0 0 24 24"><path d="M15 18l-6-6 6-6"></path></svg>
          </a>
        {% endif %}
        {% if not picker %}<p class="page-kicker">Administration</p>{% endif %}
        <h1>{{ 'Select Folder' if folder_picker else ('Select File' if picker else 'File Browser') }}</h1>
      </div>

      <div class="actions-right">
        <div class="toolbar">
          {% if picker %}
          <input id="picker-search" class="picker-search" type="search" placeholder="{{ 'Search folder...' if folder_picker else 'Search file...' }}" autocomplete="off">
          {% if folder_picker %}
          <button type="button" class="chip chip-action chip-folder" onclick="selectFile('{{ current_public_full }}')">
            <span class="modicon">
              <svg viewBox="0 0 24 24"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>
            </span>
            <span>Select this folder</span>
          </button>
          {% endif %}
          <button type="button" class="chip chip-action chip-cancel" onclick="closePicker()">
            <span class="modicon">
              <svg viewBox="0 0 24 24"><path d="M18 6L6 18"></path><path d="M6 6l12 12"></path></svg>
            </span>
            <span>Cancel</span>
          </button>
          {% else %}
          {# Upload File and New Folder buttons removed as requested #}
          {% endif %}
        </div>
      </div>
    </div>

    {% if msg %}
      <div class="alert alert-{{ alert_class }} py-2 px-3 mb-3">{{ msg }}</div>
    {% endif %}

    {% if picker %}
    <div class="table-wrap">
      <div class="card-body p-0">
    {% else %}
    <section class="overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
      <div class="max-h-[calc(100vh-190px)] overflow-auto">
    {% endif %}
        {% if entries|length == 0 %}
          <div class="empty-state">
            <div class="empty-illus">🗂️</div>
            <div class="empty-title">This folder is empty</div>
          </div>
        {% else %}
          <div class="{% if picker %}table-responsive{% endif %}">
            <table class="{% if picker %}table files-table align-middle {% endif %}standard-list-table min-w-full table-fixed divide-y divide-slate-200">
              <thead class="{% if not picker %}sticky top-0 z-10 bg-slate-100/95 backdrop-blur{% endif %}">
                <tr class="{% if not picker %}text-left text-xs font-bold uppercase tracking-wide text-slate-500{% endif %}">
                  <th class="{% if not picker %}w-[62%] px-6 py-4{% endif %}">Name</th>
                  <th class="size-col {% if not picker %}w-[14%] px-6 py-4{% endif %}" {% if picker %}style="width:14%"{% endif %}>Size</th>
                  <th class="{% if not picker %}w-[18%] px-6 py-4{% endif %}" {% if picker %}style="width:18%"{% endif %}>Modified</th>
                  {# Colonne Actions supprimée #}
                </tr>
              </thead>
              <tbody class="{% if not picker %}divide-y divide-slate-100 bg-white text-sm{% endif %}">
                {% for e in entries %}
                  <tr class="file-row {% if not picker %}odd:bg-white even:bg-slate-50/60 transition hover:bg-sky-50/60{% endif %}" data-entry-href="{{ e.href }}"{% if picker and not folder_picker and not e.is_dir %} data-select-url="{{ e.public_full }}"{% endif %}>
                    <td class="{% if not picker %}px-6 py-3 align-middle{% endif %}">
                      {% if e.is_dir %}
                        <a class="entry-link folder-link" href="{{ e.href }}">
                          <span class="entry-icon" aria-hidden="true">
                            <svg viewBox="0 0 24 24"><path d="M3 7.5A2.5 2.5 0 0 1 5.5 5h4l2 2h7A2.5 2.5 0 0 1 21 9.5v7A2.5 2.5 0 0 1 18.5 19h-13A2.5 2.5 0 0 1 3 16.5z"></path></svg>
                          </span>
                          <span class="entry-name">{{ e.name }}</span>
                        </a>
                      {% else %}
                        <a class="entry-link file-name" href="{{ '#' if picker else e.href }}">
                          <span class="entry-icon" aria-hidden="true">
                            <svg viewBox="0 0 24 24"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"></path><path d="M14 3v5h5"></path></svg>
                          </span>
                          <span class="entry-name">{{ e.name }}</span>
                        </a>
                      {% endif %}
                    </td>
                    <td class="size-col {% if not picker %}px-6 py-3 align-middle{% endif %}">{{ e.size_text }}</td>
                    <td class="{% if not picker %}px-6 py-3 align-middle{% endif %}"><span class="mtime">{{ e.mtime_short }}</span></td>
                    {# Colonne Actions supprimée #}
                    </td>
                  </tr>
                {% endfor %}
              </tbody>
            </table>
            <div id="picker-empty-filter" class="picker-empty-filter">No matching item</div>
          </div>
        {% endif %}
      {% if picker %}
      </div>
    </div>
      {% else %}
      </div>
    </section>
      {% endif %}
    {% if not picker %}</main>{% endif %}
  </div>

  {% if picker %}
  <script>
  function closePicker(){
    try{
      window.close();
    }catch(e){}
    try{
      if (window.history.length > 1) {
        window.history.back();
      }
    }catch(err){}
  }

  function selectFile(url){
    try{
      if (window.opener && typeof window.opener.setPickedFileUrl === 'function'){
        window.opener.setPickedFileUrl(url);
        setTimeout(function(){ window.close(); }, 120);
      }else{
        alert('Parent window handler not found.');
      }
    }catch(e){
      console.error(e);
      alert('Unable to send file to parent window.');
    }
  }

  const pickerSearch = document.getElementById('picker-search');
  const pickerRows = Array.prototype.slice.call(document.querySelectorAll('tr.file-row'));
  const pickerEmptyFilter = document.getElementById('picker-empty-filter');
  if (pickerSearch){
    pickerSearch.addEventListener('input', function(){
      const q = (pickerSearch.value || '').trim().toLowerCase();
      let visible = 0;
      pickerRows.forEach(function(row){
        const nameEl = row.querySelector('.entry-name');
        const name = ((nameEl && nameEl.textContent) || '').toLowerCase();
        const ok = !q || name.indexOf(q) !== -1;
        row.style.display = ok ? '' : 'none';
        if (ok) visible++;
      });
      if (pickerEmptyFilter){
        pickerEmptyFilter.style.display = visible ? 'none' : 'block';
      }
    });
  }

  document.querySelectorAll('tr.file-row').forEach(function(row){
    row.addEventListener('click', function(ev){
      const fileLink = ev.target.closest('.file-link, .file-name');
      if (fileLink) {
        ev.preventDefault();
      }
      const url = row.getAttribute('data-select-url') || '';
      const href = row.getAttribute('data-entry-href') || '';
      if (url){
        document.querySelectorAll('tr.file-row.is-selecting').forEach(function(other){
          other.classList.remove('is-selecting');
        });
        row.classList.add('is-selecting');
        selectFile(url);
        return;
      }
      if (href){
        window.location.href = href;
      }
    });
  });
  </script>
  {% else %}
  <script>
  function submitHiddenAction(action, entryName, extraFields){
    const form = document.createElement('form');
    form.method = 'post';
    form.action = {{ url_for('files.list_dir', subpath=subpath)|tojson }};

    const actionInput = document.createElement('input');
    actionInput.type = 'hidden';
    actionInput.name = 'action';
    actionInput.value = action;
    form.appendChild(actionInput);

    const entryInput = document.createElement('input');
    entryInput.type = 'hidden';
    entryInput.name = 'entry_name';
    entryInput.value = entryName;
    form.appendChild(entryInput);

    Object.keys(extraFields || {}).forEach(function(key){
      const input = document.createElement('input');
      input.type = 'hidden';
      input.name = key;
      input.value = extraFields[key];
      form.appendChild(input);
    });

    document.body.appendChild(form);
    form.submit();
  }

  function createFolder(){
    const name = window.prompt('Folder name');
    if (!name) return;
    const clean = name.trim();
    if (!clean) return;
    const input = document.getElementById('newFolderName');
    input.value = clean;
    document.getElementById('newFolderForm').submit();
  }

  document.querySelectorAll('tr.file-row').forEach(function(row){
    row.addEventListener('click', function(ev){
      if (ev.target.closest('.action-menu-wrap')) return;
      const href = row.getAttribute('data-entry-href') || '';
      if (href){
        window.location.href = href;
      }
    });
  });

  function closeActionMenus(except){
    document.querySelectorAll('.action-menu-wrap.is-open').forEach(function(menu){
      if (menu !== except){
        menu.classList.remove('is-open');
        const trigger = menu.querySelector('.action-menu-trigger');
        if (trigger) trigger.setAttribute('aria-expanded', 'false');
      }
    });
  }

  document.querySelectorAll('.action-menu-trigger').forEach(function(btn){
    btn.addEventListener('click', function(ev){
      ev.preventDefault();
      ev.stopPropagation();
      const wrap = btn.closest('.action-menu-wrap');
      const willOpen = !wrap.classList.contains('is-open');
      closeActionMenus(wrap);
      wrap.classList.toggle('is-open', willOpen);
      btn.setAttribute('aria-expanded', willOpen ? 'true' : 'false');
    });
  });

  document.querySelectorAll('.action-menu-dropdown').forEach(function(menu){
    menu.addEventListener('click', function(ev){
      ev.stopPropagation();
    });
  });

  document.addEventListener('click', function(){
    closeActionMenus(null);
  });

  document.querySelectorAll('[data-rename-entry]').forEach(function(btn){
    btn.addEventListener('click', function(ev){
      ev.preventDefault();
      ev.stopPropagation();
      const entryName = btn.getAttribute('data-rename-entry') || '';
      if (!entryName) return;
      const nextName = window.prompt('Rename entry', entryName);
      if (nextName === null) return;
      const clean = nextName.trim();
      if (!clean || clean === entryName) return;
      submitHiddenAction('rename', entryName, { new_name: clean });
    });
  });

  document.querySelectorAll('[data-delete-entry]').forEach(function(btn){
    btn.addEventListener('click', function(ev){
      ev.preventDefault();
      ev.stopPropagation();
      const entryName = btn.getAttribute('data-delete-entry') || '';
      if (!entryName) return;
      if (!window.confirm("Delete '" + entryName + "' ?")) return;
      submitHiddenAction('delete', entryName, {});
    });
  });

  </script>
  {% endif %}
</body>
</html>
    """
    resp = current_app.make_response(
        render_inline(
            tmpl,
            entries=entries,
            crumbs=crumbs,
            base=base,
            root=root,
            subpath=subpath,
            parent_href=parent_href,
            picker=picker,
            picker_target=picker_target,
            folder_picker=folder_picker,
            current_public_full=_external_base() + url_for("files.list_dir", subpath=subpath).rstrip("/"),
            msg=msg,
            alert_class=alert_class,
        )
    )
    return _no_cache(resp)

# --------- TÉLÉCHARGEMENT BRUT: /file/raw/<subpath>
@bp.route("/file/raw/<path:subpath>")
def raw_get(subpath: str):
    p = _safe_resolve(subpath)
    if not p.exists() or not p.is_file():
        abort(404)

    # Optionnel: sécuriser par jeton simple si défini
    token_required = current_app.config.get("WS_FILE_TOKEN")
    if token_required:
        if request.args.get("token") != token_required:
            abort(403)

    # as_attachment si ?download=1
    as_att = bool(request.args.get("download"))
    resp = send_from_directory(
        directory=str(p.parent),
        path=p.name,
        as_attachment=as_att,
        conditional=False,
        max_age=0,
        etag=False,
    )
    return _no_cache(resp)
