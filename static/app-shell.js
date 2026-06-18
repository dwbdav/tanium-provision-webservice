(function () {
  "use strict";

  const MODULES = [
    { key: "computers", label: "Computers", href: "/computers", section: "Inventory", icon: "monitor" },
    { key: "apps", label: "Apps", href: "/apps", section: "Configuration", icon: "apps" },
    { key: "types", label: "Type Mapping", href: "/type", section: "Configuration", icon: "layers" },
    { key: "drivers", label: "Model", href: "/drivers", section: "Configuration", icon: "chip" },
    { key: "progress", label: "Progress", href: "/progress", section: "Deployment Activity", icon: "activity" },
    { key: "files", label: "Files", href: "/file/", section: "Management", icon: "folder", adminOnly: true },
    { key: "users", label: "Users", href: "/users", section: "Management", icon: "users", adminOnly: true },
    { key: "network", label: "Network", href: "/network", section: "Management", icon: "shield", adminOnly: true },
  ];

  const SECTION_ORDER = ["Inventory", "Configuration", "Deployment Activity", "Management"];

  function normalizePath(path) {
    const input = (path || "/").replace(/\\+/g, "/");
    const noQuery = input.split("?")[0].split("#")[0];
    let normalized = noQuery.replace(/\/+/g, "/");
    if (!normalized.startsWith("/")) normalized = "/" + normalized;
    if (normalized.length > 1) normalized = normalized.replace(/\/+$/, "");
    return normalized || "/";
  }

  function joinPath(base, path) {
    const left = (base || "").replace(/\/+$/, "");
    const right = (path || "").replace(/^\/+/, "");
    const out = normalizePath((left ? left : "") + "/" + right);
    return out === "" ? "/" : out;
  }

  function iconSvg(kind) {
    const map = {
      monitor: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="4" width="18" height="12" rx="2"></rect><path d="M8 20h8M12 16v4"></path></svg>',
      home: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 10.5 12 3l9 7.5"></path><path d="M5 10v10h14V10"></path><path d="M10 20v-6h4v6"></path></svg>',
      chip: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="8" y="8" width="8" height="8" rx="1"></rect><path d="M4 10h2M4 14h2M18 10h2M18 14h2M10 4v2M14 4v2M10 18v2M14 18v2"></path></svg>',
      apps: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="4" width="6" height="6" rx="1"></rect><rect x="14" y="4" width="6" height="6" rx="1"></rect><rect x="4" y="14" width="6" height="6" rx="1"></rect><rect x="14" y="14" width="6" height="6" rx="1"></rect></svg>',
      gear: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="3"></circle><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3h.1a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5h.1a1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8v.1a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"></path></svg>',
      layers: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m12 3 9 5-9 5-9-5 9-5z"></path><path d="m3 12 9 5 9-5"></path><path d="m3 16 9 5 9-5"></path></svg>',
      pulse: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 12h4l2 6 4-12 2 6h6"></path></svg>',
      activity: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9"></circle><path d="M8 12h2l1.5-3 2.5 6 1.5-3H18"></path></svg>',
      folder: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 7a2 2 0 0 1 2-2h5l2 2h7a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"></path></svg>',
      users: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M16 21v-2a4 4 0 0 0-4-4H7a4 4 0 0 0-4 4v2"></path><circle cx="9.5" cy="7" r="3"></circle><path d="M20 21v-2a4 4 0 0 0-3-3.87"></path><path d="M16.5 4.2a3 3 0 0 1 0 5.6"></path></svg>',
      shield: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3l8 3v5c0 5-3.5 8-8 10-4.5-2-8-5-8-10V6z"></path></svg>',
    };
    return map[kind] || map.monitor;
  }

  function inferBasePrefix() {
    const logoutLink = document.querySelector('a[href$="/logout"],a[href*="/logout?"]');
    if (logoutLink) {
      const href = normalizePath(logoutLink.getAttribute("href") || "");
      return href.replace(/\/logout$/, "") || "";
    }

    const dashboardLink = Array.from(document.querySelectorAll("a[href]")).find((a) => {
      const text = (a.textContent || "").replace(/\s+/g, " ").trim().toLowerCase();
      return text === "dashboard";
    });
    if (dashboardLink) {
      const href = normalizePath(dashboardLink.getAttribute("href") || "/");
      return href === "/" ? "" : href.replace(/\/$/, "");
    }

    const path = normalizePath(window.location.pathname || "/");
    for (const mod of MODULES) {
      if (path === mod.href || path.startsWith(mod.href + "/")) return "";
      const idx = path.indexOf(mod.href + "/");
      if (idx > 0) return path.slice(0, idx);
      if (path.endsWith(mod.href) && path.length > mod.href.length) {
        return path.slice(0, path.length - mod.href.length);
      }
    }
    return "";
  }

  function getScriptMeta() {
    const script = document.querySelector('script[data-app-shell="1"][src*="app-shell.js"]');
    if (!script) return { username: "", role: "" };
    return {
      username: (script.dataset.username || "").trim(),
      role: (script.dataset.role || "").trim(),
    };
  }

  function isPickerMode() {
    try {
      const params = new URLSearchParams(window.location.search || "");
      return (params.get("picker") || "").trim() === "1";
    } catch (err) {
      return false;
    }
  }

  function getCurrentModule(pathNoBase) {
    for (const mod of MODULES) {
      if (pathNoBase === mod.href || pathNoBase.startsWith(mod.href + "/")) return mod;
    }
    return null;
  }

  function buildSidebar(basePrefix, pathNoBase, role) {
    const sidebar = document.createElement("aside");
    sidebar.className = "app-sidebar";

    const brand = document.createElement("a");
    brand.className = "app-brand";
    brand.href = joinPath(basePrefix, "/");
    brand.innerHTML = '<span class="brand-badge" aria-label="WS">WS</span>';
    sidebar.appendChild(brand);

    const roleLower = (role || "").toLowerCase();
    for (const section of SECTION_ORDER) {
      const group = document.createElement("div");
      group.className = "sidebar-group";

      const heading = document.createElement("div");
      heading.className = "sidebar-heading";
      heading.textContent = section;
      group.appendChild(heading);

      const list = document.createElement("div");
      list.className = "sidebar-links";

      MODULES.filter((m) => m.section === section).forEach((item) => {
        if (item.adminOnly && roleLower && roleLower !== "admin") return;

        const a = document.createElement("a");
        const itemHref = normalizePath(item.href);
        const active = pathNoBase === itemHref || pathNoBase.startsWith(itemHref + "/");
        a.className = "sidebar-link" + (active ? " is-active" : "");
        a.href = joinPath(basePrefix, item.href);
        a.innerHTML = `<span class="icon-wrap">${iconSvg(item.icon)}</span><span>${item.label}</span>`;
        list.appendChild(a);
      });

      group.appendChild(list);
      sidebar.appendChild(group);
    }

    return sidebar;
  }

  function hideLegacyDashboardButtons(root) {
    const links = root.querySelectorAll("a");
    links.forEach((link) => {
      const text = (link.textContent || "").replace(/\s+/g, " ").trim().toLowerCase();
      if (text === "dashboard") {
        link.classList.add("legacy-dashboard-link");
      }
    });
  }

  function removeDashboardNavCards(root, pathNoBase) {
    if (pathNoBase !== "/") return;
    const sectionTitles = Array.from(root.querySelectorAll(".section-title,.nav-subtitle,h5"));
    for (const title of sectionTitles) {
      const txt = (title.textContent || "").replace(/\s+/g, " ").trim().toLowerCase();
      if (txt !== "navigation") continue;
      const section = title.closest(".section-block") || title.closest(".card") || title.parentElement;
      if (section) {
        section.remove();
      }
      break;
    }
  }

  function buildHeader(basePrefix, username, role) {
    const header = document.createElement("header");
    header.className = "app-header";

    const roleLabel = role ? role.charAt(0).toUpperCase() + role.slice(1) : "User";
    const userLabel = username || "admin";
    const initials = userLabel.slice(0, 1).toUpperCase() || "A";

    header.innerHTML = `
      <div class="app-header-right">
        <details class="user-menu" id="app-user-menu">
          <summary>
            <span class="user-avatar">${initials}</span>
            <span class="user-meta"><strong>${userLabel}</strong><small>${roleLabel}</small></span>
            <span class="caret">▾</span>
          </summary>
          <div class="user-menu-panel">
            <a href="${joinPath(basePrefix, "/account/password")}">Change password</a>
            <a href="${joinPath(basePrefix, "/logout")}" class="danger">Logout</a>
          </div>
        </details>
      </div>
    `;

    document.addEventListener("click", (ev) => {
      const details = header.querySelector("#app-user-menu");
      if (!details) return;
      if (!details.contains(ev.target)) details.removeAttribute("open");
    });

    return header;
  }

  function buildBreadcrumbs(basePrefix, pathNoBase, currentModule, pageTitle) {
    const isDashboard = pathNoBase === "/";
    if (isDashboard) return null;
    if (!/\/edit(?:\/|$)/i.test(pathNoBase || "")) return null;

    const wrap = document.createElement("div");
    wrap.className = "page-breadcrumb-inline";

    const breadcrumb = document.createElement("nav");
    breadcrumb.className = "app-breadcrumb";
    breadcrumb.setAttribute("aria-label", "Breadcrumb");

    const list = document.createElement("ol");

    const first = document.createElement("li");
    first.innerHTML = `<a href="${joinPath(basePrefix, "/")}">Dashboard</a>`;
    list.appendChild(first);

    if (currentModule && currentModule.label.toLowerCase() !== "dashboard") {
      const moduleItem = document.createElement("li");
      moduleItem.innerHTML = `<a href="${joinPath(basePrefix, currentModule.href)}">${currentModule.label}</a>`;
      list.appendChild(moduleItem);
    }

    if (!isDashboard && pageTitle) {
      const moduleLabel = currentModule ? currentModule.label.toLowerCase() : "";
      const titleLower = pageTitle.toLowerCase();
      if (!moduleLabel || titleLower !== moduleLabel) {
        const tail = document.createElement("li");
        tail.className = "current";
        tail.textContent = pageTitle;
        list.appendChild(tail);
      }
    }

    breadcrumb.appendChild(list);
    wrap.appendChild(breadcrumb);

    return wrap;
  }

  function shouldShowEditBack(pathNoBase) {
    if (/^\/drivers\/edit(?:\/|$)/i.test(pathNoBase || "")) return false;
    return /\/edit(?:\/|$)/i.test(pathNoBase || "");
  }

  function shouldSuppressInlineContext(pathNoBase, currentModule) {
    if (/^\/users\/[^/]+\/edit(?:\/|$)/i.test(pathNoBase || "")) return true;
    if (/^\/drivers\/edit(?:\/|$)/i.test(pathNoBase || "")) return true;
    if (/^\/drivers\/[^/]+\/edit(?:\/|$)/i.test(pathNoBase || "")) return true;
    if (/^\/apps\/[^/]+\/edit(?:\/|$)/i.test(pathNoBase || "")) return true;
    if (/^\/computers\/[^/]+\/edit(?:\/|$)/i.test(pathNoBase || "")) return true;

    const moduleKey = currentModule && currentModule.key ? String(currentModule.key).toLowerCase() : "";
    if (moduleKey !== "types") return false;
    return /^\/type(?:\/.+)?\/edit(?:\/|$)/i.test(pathNoBase || "");
  }

  function injectInlineContext(content, basePrefix, pathNoBase, currentModule) {
    const firstHeading = content.querySelector("h1");
    const pageTitle = firstHeading
      ? (firstHeading.textContent || "").replace(/\s+/g, " ").trim()
      : "";

    if (shouldSuppressInlineContext(pathNoBase, currentModule)) {
      return;
    }

    const crumb = buildBreadcrumbs(basePrefix, pathNoBase, currentModule, pageTitle);
    if (crumb) {
      if (firstHeading && firstHeading.parentElement) {
        firstHeading.parentElement.insertBefore(crumb, firstHeading);
      } else {
        content.prepend(crumb);
      }
    }

    if (firstHeading && shouldShowEditBack(pathNoBase) && !firstHeading.querySelector(".title-back-link")) {
      const fallback = currentModule ? joinPath(basePrefix, currentModule.href) : joinPath(basePrefix, "/");
      const back = document.createElement("a");
      back.className = "title-back-link";
      back.href = fallback;
      back.textContent = "← Retour";
      firstHeading.classList.add("has-inline-back");
      firstHeading.prepend(back);
    }
  }

  function enableShell() {
    if (window.__dwsShellApplied) return;
    window.__dwsShellApplied = true;

    const currentPath = normalizePath(window.location.pathname || "/");
    if (/\/login$/.test(currentPath)) return;
    if (/^\d{3}\b/.test((document.title || "").trim())) return;
    if (isPickerMode()) {
      document.body.classList.add("picker-mode");
      return;
    }

    const containers = Array.from(document.body.children).filter(
      (el) => el.classList && el.classList.contains("container-fluid")
    );
    if (!containers.length) return;

    const basePrefix = inferBasePrefix();
    const pathNoBase = currentPath.startsWith(basePrefix)
      ? normalizePath(currentPath.slice(basePrefix.length) || "/")
      : currentPath;

    const meta = getScriptMeta();
    const currentModule = getCurrentModule(pathNoBase);

    document.body.classList.add("shell-enabled");

    const shell = document.createElement("div");
    shell.className = "app-shell";

    const sidebar = buildSidebar(basePrefix, pathNoBase, meta.role);
    const main = document.createElement("div");
    main.className = "app-main";

    const header = buildHeader(basePrefix, meta.username, meta.role);
    const content = document.createElement("main");
    content.className = "app-content";

    const first = containers[0];
    document.body.insertBefore(shell, first);

    containers.forEach((node) => {
      content.appendChild(node);
    });

    main.appendChild(header);
    main.appendChild(content);

    shell.appendChild(sidebar);
    shell.appendChild(main);

    hideLegacyDashboardButtons(content);
    removeDashboardNavCards(content, pathNoBase);
    injectInlineContext(content, basePrefix, pathNoBase, currentModule);

    content.querySelectorAll(".topbar-actions").forEach((el) => el.remove());
  }

  document.addEventListener("DOMContentLoaded", enableShell);
})();
