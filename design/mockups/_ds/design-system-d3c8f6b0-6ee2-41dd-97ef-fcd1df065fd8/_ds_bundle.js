/* @ds-bundle: {"namespace":"TagaiUi","components":[{"name":"AiBadge","sourcePath":"components/primitivos/AiBadge/AiBadge.jsx"},{"name":"Avatar","sourcePath":"components/primitivos/Avatar/Avatar.jsx"},{"name":"Banner","sourcePath":"components/layout/Banner/Banner.jsx"},{"name":"Button","sourcePath":"components/primitivos/Button/Button.jsx"},{"name":"Card","sourcePath":"components/primitivos/Card/Card.jsx"},{"name":"Chip","sourcePath":"components/primitivos/Chip/Chip.jsx"},{"name":"EmptyState","sourcePath":"components/layout/EmptyState/EmptyState.jsx"},{"name":"Input","sourcePath":"components/formularios/Input/Input.jsx"},{"name":"KeyBadge","sourcePath":"components/primitivos/KeyBadge/KeyBadge.jsx"},{"name":"NotificationDot","sourcePath":"components/primitivos/NotificationDot/NotificationDot.jsx"},{"name":"ProgressBar","sourcePath":"components/primitivos/ProgressBar/ProgressBar.jsx"},{"name":"Sidebar","sourcePath":"components/layout/Sidebar/Sidebar.jsx"},{"name":"SidebarItem","sourcePath":"components/layout/SidebarItem/SidebarItem.jsx"},{"name":"StatCard","sourcePath":"components/layout/StatCard/StatCard.jsx"},{"name":"StatusPill","sourcePath":"components/primitivos/StatusPill/StatusPill.jsx"},{"name":"Switch","sourcePath":"components/primitivos/Switch/Switch.jsx"},{"name":"Textarea","sourcePath":"components/formularios/Textarea/Textarea.jsx"},{"name":"TopBar","sourcePath":"components/layout/TopBar/TopBar.jsx"}],"sourceHashes":{"components/primitivos/AiBadge/AiBadge.jsx":"e9f8f3a3aaf4","components/primitivos/AiBadge/AiBadge.d.ts":"ff115385dc69","components/primitivos/AiBadge/AiBadge.prompt.md":"754d806a7d9c","components/primitivos/Avatar/Avatar.jsx":"e41019532b96","components/primitivos/Avatar/Avatar.d.ts":"d8ee82f1a249","components/primitivos/Avatar/Avatar.prompt.md":"780c9e0c3b97","components/layout/Banner/Banner.jsx":"0d41a40d57ae","components/layout/Banner/Banner.d.ts":"56a2dde02bce","components/layout/Banner/Banner.prompt.md":"7317c266c6bc","components/primitivos/Button/Button.jsx":"ef9f6f201e9e","components/primitivos/Button/Button.d.ts":"880a18efbe67","components/primitivos/Button/Button.prompt.md":"265501344d1a","components/primitivos/Card/Card.jsx":"84e537a2ef3a","components/primitivos/Card/Card.d.ts":"8683b1070159","components/primitivos/Card/Card.prompt.md":"18de82804410","components/primitivos/Chip/Chip.jsx":"05f6bc7b6fef","components/primitivos/Chip/Chip.d.ts":"fe6e18c3004f","components/primitivos/Chip/Chip.prompt.md":"0b9eb34b8024","components/layout/EmptyState/EmptyState.jsx":"fb789ecb5f3c","components/layout/EmptyState/EmptyState.d.ts":"ba2e33b2b521","components/layout/EmptyState/EmptyState.prompt.md":"1db0f0cbec19","components/formularios/Input/Input.jsx":"60b9ad330811","components/formularios/Input/Input.d.ts":"d1362aa4ba8a","components/formularios/Input/Input.prompt.md":"80a5045f7722","components/primitivos/KeyBadge/KeyBadge.jsx":"328def7713ee","components/primitivos/KeyBadge/KeyBadge.d.ts":"ca90c6f9e902","components/primitivos/KeyBadge/KeyBadge.prompt.md":"2aab6780c199","components/primitivos/NotificationDot/NotificationDot.jsx":"8f35d9b1fb7b","components/primitivos/NotificationDot/NotificationDot.d.ts":"f06d40ac7376","components/primitivos/NotificationDot/NotificationDot.prompt.md":"2a2c8de74185","components/primitivos/ProgressBar/ProgressBar.jsx":"1cc472d1ab1a","components/primitivos/ProgressBar/ProgressBar.d.ts":"5b055d9e6dd2","components/primitivos/ProgressBar/ProgressBar.prompt.md":"ef70f43944ab","components/layout/Sidebar/Sidebar.jsx":"ac80c752779a","components/layout/Sidebar/Sidebar.d.ts":"11f556723d22","components/layout/Sidebar/Sidebar.prompt.md":"4075edfd7b03","components/layout/SidebarItem/SidebarItem.jsx":"18d3c4edc852","components/layout/SidebarItem/SidebarItem.d.ts":"705c1923dba8","components/layout/SidebarItem/SidebarItem.prompt.md":"1bbec05cf11f","components/layout/StatCard/StatCard.jsx":"0a572383800e","components/layout/StatCard/StatCard.d.ts":"383022730aee","components/layout/StatCard/StatCard.prompt.md":"1e92ffcb7848","components/primitivos/StatusPill/StatusPill.jsx":"f9c4af3f4687","components/primitivos/StatusPill/StatusPill.d.ts":"b697ec8f1af9","components/primitivos/StatusPill/StatusPill.prompt.md":"4f3003564e13","components/primitivos/Switch/Switch.jsx":"080d25395cab","components/primitivos/Switch/Switch.d.ts":"4ec4aa13f138","components/primitivos/Switch/Switch.prompt.md":"48e5034d0e93","components/formularios/Textarea/Textarea.jsx":"67e014b797ef","components/formularios/Textarea/Textarea.d.ts":"e698e49b38bf","components/formularios/Textarea/Textarea.prompt.md":"c679a0c23465","components/layout/TopBar/TopBar.jsx":"8a6b5e9aa6b4","components/layout/TopBar/TopBar.d.ts":"a8f8432a1ca7","components/layout/TopBar/TopBar.prompt.md":"e3dc6efd4f17"},"inlinedExternals":[],"builtBy":"cc-design-sync"} */
"use strict";
var TagaiUi = (() => {
  var __create = Object.create;
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __getProtoOf = Object.getPrototypeOf;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __esm = (fn, res, err) => function __init() {
    if (err) throw err[0];
    try {
      return fn && (res = (0, fn[__getOwnPropNames(fn)[0]])(fn = 0)), res;
    } catch (e) {
      throw err = [e], e;
    }
  };
  var __commonJS = (cb, mod) => function __require() {
    try {
      return mod || (0, cb[__getOwnPropNames(cb)[0]])((mod = { exports: {} }).exports, mod), mod.exports;
    } catch (e) {
      throw mod = 0, e;
    }
  };
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
    // If the importer is in node compatibility mode or this is not an ESM
    // file that has been converted to a CommonJS file using a Babel-
    // compatible transform (i.e. "__esModule" has not been set), then set
    // "default" to the CommonJS "module.exports" for node compatibility.
    isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
    mod
  ));
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // <define:import.meta.env>
  var init_define_import_meta_env = __esm({
    "<define:import.meta.env>"() {
    }
  });

  // shim:react-shim
  var require_react_shim = __commonJS({
    "shim:react-shim"(exports, module) {
      init_define_import_meta_env();
      var R = window.React;
      function np(p, k) {
        var o = {};
        for (var x in p) if (x !== "children") o[x] = p[x];
        if (k !== void 0) o.key = k;
        return o;
      }
      function jsx(t, p, k) {
        var c = p && p.children;
        return c === void 0 ? R.createElement(t, np(p, k)) : R.createElement(t, np(p, k), c);
      }
      function jsxs(t, p, k) {
        return R.createElement.apply(R, [t, np(p, k)].concat(p.children));
      }
      module.exports = R;
      module.exports.jsx = jsx;
      module.exports.jsxs = jsxs;
      module.exports.jsxDEV = function(t, p, k, s) {
        return (s ? jsxs : jsx)(t, p, k);
      };
      module.exports.Fragment = R.Fragment;
    }
  });

  // packages/ui/dist/index.js
  var index_exports = {};
  __export(index_exports, {
    AiBadge: () => AiBadge,
    Avatar: () => Avatar,
    Banner: () => Banner,
    Button: () => Button,
    Card: () => Card,
    Chip: () => Chip,
    EmptyState: () => EmptyState,
    Input: () => Input,
    KeyBadge: () => KeyBadge,
    NotificationDot: () => NotificationDot,
    ProgressBar: () => ProgressBar,
    Sidebar: () => Sidebar,
    SidebarItem: () => SidebarItem,
    StatCard: () => StatCard,
    StatusPill: () => StatusPill,
    Switch: () => Switch,
    TAG_NAV_ITEMS: () => TAG_NAV_ITEMS,
    Textarea: () => Textarea,
    TopBar: () => TopBar
  });
  init_define_import_meta_env();

  // packages/ui/dist/components/Button.js
  init_define_import_meta_env();
  var import_jsx_runtime = __toESM(require_react_shim(), 1);
  function Button({ variant = "primary", size = "md", icon, children, ...rest }) {
    return (0, import_jsx_runtime.jsxs)("button", { className: `tag-btn tag-btn--${variant} tag-btn--${size}`, ...rest, children: [icon ? (0, import_jsx_runtime.jsx)("span", { className: "tag-icon", children: icon }) : null, children] });
  }

  // packages/ui/dist/components/Card.js
  init_define_import_meta_env();
  var import_jsx_runtime2 = __toESM(require_react_shim(), 1);
  function Card({ padding = "md", children, ...rest }) {
    return (0, import_jsx_runtime2.jsx)("div", { className: `tag-card tag-card--padding-${padding}`, ...rest, children });
  }

  // packages/ui/dist/components/Chip.js
  init_define_import_meta_env();
  var import_jsx_runtime3 = __toESM(require_react_shim(), 1);
  var DEFAULT_ICON = {
    decisao: "gavel",
    acao: "task_alt",
    impedimento: "block",
    insight: "lightbulb",
    momento: "bookmark"
  };
  function Chip({ variant, icon, children, ...rest }) {
    const resolvedIcon = icon ?? DEFAULT_ICON[variant];
    return (0, import_jsx_runtime3.jsxs)("span", { className: `tag-chip tag-chip--${variant}`, ...rest, children: [resolvedIcon ? (0, import_jsx_runtime3.jsx)("span", { className: "tag-icon", style: { fontSize: 14 }, children: resolvedIcon }) : null, children] });
  }

  // packages/ui/dist/components/StatusPill.js
  init_define_import_meta_env();
  var import_jsx_runtime4 = __toESM(require_react_shim(), 1);
  var DEFAULT_LABEL = {
    pendente: "Pendente",
    proposta: "Proposta",
    aprovada: "Aprovada",
    executada: "Executada",
    rejeitada: "Rejeitada",
    falhou: "Falhou"
  };
  function StatusPill({ status, label, ...rest }) {
    return (0, import_jsx_runtime4.jsxs)("span", { className: `tag-status-pill tag-status-pill--${status}`, ...rest, children: [(0, import_jsx_runtime4.jsx)("span", { className: "tag-status-pill__dot" }), label ?? DEFAULT_LABEL[status]] });
  }

  // packages/ui/dist/components/Avatar.js
  init_define_import_meta_env();
  var import_jsx_runtime5 = __toESM(require_react_shim(), 1);
  function initials(name) {
    const parts = name.trim().split(/\s+/);
    const first = parts[0]?.[0] ?? "";
    const last = parts.length > 1 ? parts[parts.length - 1]?.[0] ?? "" : "";
    return (first + last).toUpperCase();
  }
  function Avatar({ name, src, size = "md", ...rest }) {
    return (0, import_jsx_runtime5.jsx)("span", { className: `tag-avatar tag-avatar--${size}`, ...rest, children: src ? (0, import_jsx_runtime5.jsx)("img", { src, alt: name }) : initials(name) });
  }

  // packages/ui/dist/components/Badge.js
  init_define_import_meta_env();
  var import_jsx_runtime6 = __toESM(require_react_shim(), 1);
  function AiBadge(props) {
    return (0, import_jsx_runtime6.jsxs)("span", { className: "tag-ai-badge", ...props, children: [(0, import_jsx_runtime6.jsx)("span", { className: "tag-icon", style: { fontSize: 12 }, children: "auto_awesome" }), "IA"] });
  }
  function KeyBadge({ keyLabel, ...rest }) {
    return (0, import_jsx_runtime6.jsx)("span", { className: "tag-key-badge", ...rest, children: keyLabel });
  }
  function NotificationDot(props) {
    return (0, import_jsx_runtime6.jsx)("span", { className: "tag-notification-dot", ...props });
  }

  // packages/ui/dist/components/ProgressBar.js
  init_define_import_meta_env();
  var import_jsx_runtime7 = __toESM(require_react_shim(), 1);
  function ProgressBar({ value, ...rest }) {
    const clamped = Math.max(0, Math.min(100, value));
    return (0, import_jsx_runtime7.jsx)("div", { className: "tag-progress", role: "progressbar", "aria-valuenow": clamped, "aria-valuemin": 0, "aria-valuemax": 100, ...rest, children: (0, import_jsx_runtime7.jsx)("div", { className: "tag-progress__fill", style: { width: `${clamped}%` } }) });
  }

  // packages/ui/dist/components/Switch.js
  init_define_import_meta_env();
  var import_jsx_runtime8 = __toESM(require_react_shim(), 1);
  function Switch({ label, ...rest }) {
    return (0, import_jsx_runtime8.jsxs)("label", { className: "tag-switch", children: [(0, import_jsx_runtime8.jsx)("input", { type: "checkbox", className: "tag-switch__input", ...rest }), (0, import_jsx_runtime8.jsx)("span", { className: "tag-switch__track" }), label ? (0, import_jsx_runtime8.jsx)("span", { className: "tag-switch__label", children: label }) : null] });
  }

  // packages/ui/dist/components/EmptyState.js
  init_define_import_meta_env();
  var import_jsx_runtime9 = __toESM(require_react_shim(), 1);
  function EmptyState({ icon, title, description, action }) {
    return (0, import_jsx_runtime9.jsxs)("div", { className: "tag-empty-state", children: [(0, import_jsx_runtime9.jsx)("span", { className: "tag-empty-state__icon", children: (0, import_jsx_runtime9.jsx)("span", { className: "tag-icon", children: icon }) }), (0, import_jsx_runtime9.jsx)("p", { className: "tag-empty-state__title", children: title }), (0, import_jsx_runtime9.jsx)("p", { className: "tag-empty-state__description", children: description }), action] });
  }

  // packages/ui/dist/components/StatCard.js
  init_define_import_meta_env();
  var import_jsx_runtime10 = __toESM(require_react_shim(), 1);
  function StatCard({ value, label, caption }) {
    return (0, import_jsx_runtime10.jsx)(Card, { children: (0, import_jsx_runtime10.jsxs)("div", { className: "tag-stat-card", children: [(0, import_jsx_runtime10.jsx)("span", { className: "tag-stat-card__value", children: value }), (0, import_jsx_runtime10.jsx)("span", { className: "tag-stat-card__label", children: label }), caption ? (0, import_jsx_runtime10.jsx)("span", { className: "tag-stat-card__caption", children: caption }) : null] }) });
  }

  // packages/ui/dist/components/Banner.js
  init_define_import_meta_env();
  var import_jsx_runtime11 = __toESM(require_react_shim(), 1);
  function Banner({ variant = "info", title, description, onDismiss }) {
    return (0, import_jsx_runtime11.jsxs)("div", { className: `tag-banner tag-banner--${variant}`, children: [onDismiss ? (0, import_jsx_runtime11.jsx)("button", { type: "button", className: "tag-banner__dismiss", onClick: onDismiss, "aria-label": "Fechar", children: (0, import_jsx_runtime11.jsx)("span", { className: "tag-icon", children: "close" }) }) : null, (0, import_jsx_runtime11.jsx)("span", { className: "tag-banner__title", children: title }), (0, import_jsx_runtime11.jsx)("span", { className: "tag-banner__description", children: description })] });
  }

  // packages/ui/dist/components/Sidebar.js
  init_define_import_meta_env();
  var import_jsx_runtime12 = __toESM(require_react_shim(), 1);
  var TAG_NAV_ITEMS = [
    { key: "inicio", label: "In\xEDcio", icon: "home" },
    { key: "reunioes", label: "Reuni\xF5es", icon: "forum" },
    { key: "momentos", label: "Momentos", icon: "bookmark" },
    { key: "rituais", label: "Rituais", icon: "calendar_month" },
    { key: "insights", label: "Insights", icon: "lightbulb" },
    { key: "acoes", label: "A\xE7\xF5es", icon: "check_circle" },
    { key: "integracoes", label: "Integra\xE7\xF5es", icon: "extension" },
    { key: "configuracoes", label: "Configura\xE7\xF5es", icon: "settings" }
  ];
  function SidebarItem({ icon, label, active, onClick, href }) {
    const className = `tag-sidebar-item${active ? " tag-sidebar-item--active" : ""}`;
    const content = (0, import_jsx_runtime12.jsxs)(import_jsx_runtime12.Fragment, { children: [(0, import_jsx_runtime12.jsx)("span", { className: "tag-icon", children: icon }), label] });
    if (href) {
      return (0, import_jsx_runtime12.jsx)("a", { className, href, onClick, children: content });
    }
    return (0, import_jsx_runtime12.jsx)("button", { type: "button", className, onClick, children: content });
  }
  function Sidebar({ activeKey, onNavigate, hrefFor }) {
    return (0, import_jsx_runtime12.jsxs)("nav", { className: "tag-sidebar", children: [(0, import_jsx_runtime12.jsxs)("div", { children: [(0, import_jsx_runtime12.jsxs)("div", { className: "tag-sidebar__brand", children: [(0, import_jsx_runtime12.jsx)("span", { className: "tag-sidebar__brand-glyph", children: (0, import_jsx_runtime12.jsx)("span", { className: "tag-icon", children: "bookmark" }) }), (0, import_jsx_runtime12.jsxs)("div", { children: [(0, import_jsx_runtime12.jsx)("div", { className: "tag-sidebar__brand-name", children: "Tag AI" }), (0, import_jsx_runtime12.jsx)("div", { className: "tag-sidebar__brand-subtitle", children: "Intelig\xEAncia de Reuni\xF5es" })] })] }), (0, import_jsx_runtime12.jsx)("div", { className: "tag-sidebar__nav", children: TAG_NAV_ITEMS.map((item) => (0, import_jsx_runtime12.jsx)(SidebarItem, { icon: item.icon, label: item.label, active: item.key === activeKey, onClick: onNavigate ? () => onNavigate(item.key) : void 0, href: hrefFor ? hrefFor(item.key) : void 0 }, item.key)) })] }), (0, import_jsx_runtime12.jsxs)("div", { className: "tag-sidebar__footer", children: [(0, import_jsx_runtime12.jsx)(SidebarItem, { icon: "help", label: "Ajuda", onClick: onNavigate ? () => onNavigate("ajuda") : void 0, href: hrefFor ? hrefFor("ajuda") : void 0 }), (0, import_jsx_runtime12.jsx)(SidebarItem, { icon: "logout", label: "Sair", onClick: onNavigate ? () => onNavigate("sair") : void 0, href: hrefFor ? hrefFor("sair") : void 0 })] })] });
  }

  // packages/ui/dist/components/TopBar.js
  init_define_import_meta_env();
  var import_jsx_runtime13 = __toESM(require_react_shim(), 1);
  function TopBar({ searchPlaceholder = "Buscar reuni\xF5es...", onSearchChange, primaryAction, hasNotifications, onBellClick, userName, userAvatarSrc }) {
    return (0, import_jsx_runtime13.jsxs)("div", { className: "tag-topbar", children: [(0, import_jsx_runtime13.jsxs)("label", { className: "tag-topbar__search", children: [(0, import_jsx_runtime13.jsx)("span", { className: "tag-icon", style: { fontSize: 18 }, children: "search" }), (0, import_jsx_runtime13.jsx)("input", { type: "text", placeholder: searchPlaceholder, onChange: (event) => onSearchChange?.(event.target.value) })] }), (0, import_jsx_runtime13.jsxs)("div", { className: "tag-topbar__actions", children: [primaryAction, (0, import_jsx_runtime13.jsxs)("button", { type: "button", className: "tag-topbar__bell", onClick: onBellClick, "aria-label": "Notifica\xE7\xF5es", children: [(0, import_jsx_runtime13.jsx)("span", { className: "tag-icon", children: "notifications" }), hasNotifications ? (0, import_jsx_runtime13.jsx)(NotificationDot, {}) : null] }), (0, import_jsx_runtime13.jsxs)("div", { className: "tag-topbar__user", children: [(0, import_jsx_runtime13.jsx)(Avatar, { name: userName, src: userAvatarSrc, size: "sm" }), userName] })] })] });
  }

  // packages/ui/dist/components/FormField.js
  init_define_import_meta_env();
  var import_jsx_runtime14 = __toESM(require_react_shim(), 1);
  function FieldWrapper({ label, hint, children }) {
    return (0, import_jsx_runtime14.jsxs)("label", { className: "tag-field", children: [label ? (0, import_jsx_runtime14.jsx)("span", { className: "tag-field__label", children: label }) : null, children, hint ? (0, import_jsx_runtime14.jsx)("span", { className: "tag-field__hint", children: hint }) : null] });
  }
  function Input({ label, hint, ...rest }) {
    return (0, import_jsx_runtime14.jsx)(FieldWrapper, { label, hint, children: (0, import_jsx_runtime14.jsx)("input", { className: "tag-input", ...rest }) });
  }
  function Textarea({ label, hint, ...rest }) {
    return (0, import_jsx_runtime14.jsx)(FieldWrapper, { label, hint, children: (0, import_jsx_runtime14.jsx)("textarea", { className: "tag-textarea", ...rest }) });
  }
  return __toCommonJS(index_exports);
})();
window.TagaiUi=TagaiUi.__dsMainNs?Object.assign({},TagaiUi,TagaiUi.__dsMainNs,{__dsMainNs:undefined}):TagaiUi;
