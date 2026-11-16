// SPDX-License-Identifier: GPL-3.0-only
// PerAnt 官网：导航折叠、截图切换、复制 SHA256。无外部依赖。
(function () {
  'use strict';

  var root = document.documentElement;
  root.classList.add('js');

  var reduceMotion = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)');

  /* ---------- 顶栏：滚动描边 ---------- */
  var header = document.querySelector('.site-header');
  function onScroll() {
    if (header) header.classList.toggle('is-scrolled', window.scrollY > 8);
  }
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  /* ---------- 手机端菜单 ---------- */
  var toggle = document.querySelector('.menu-toggle');
  var nav = document.getElementById('site-nav');
  var toggleLabel = toggle ? toggle.querySelector('.menu-toggle-label') : null;

  function setMenu(open, returnFocus) {
    if (!toggle || !nav) return;
    nav.classList.toggle('is-open', open);
    toggle.setAttribute('aria-expanded', String(open));
    if (toggleLabel) toggleLabel.textContent = open ? '关闭' : '菜单';
    if (!open && returnFocus) toggle.focus();
  }

  if (toggle && nav) {
    toggle.addEventListener('click', function () {
      setMenu(toggle.getAttribute('aria-expanded') !== 'true', false);
    });
    nav.addEventListener('click', function (e) {
      if (e.target.closest('a')) setMenu(false, false);
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && nav.classList.contains('is-open')) setMenu(false, true);
    });
    document.addEventListener('click', function (e) {
      if (nav.classList.contains('is-open') && !nav.contains(e.target) && !toggle.contains(e.target)) setMenu(false, false);
    });
    var wide = window.matchMedia('(min-width: 861px)');
    var onWide = function () { if (wide.matches) setMenu(false, false); };
    if (wide.addEventListener) wide.addEventListener('change', onWide);
    else if (wide.addListener) wide.addListener(onWide);
  }

  /* ---------- 三个入口：选项卡 ---------- */
  var tabsRoot = document.querySelector('[data-tabs]');
  if (tabsRoot) {
    var tabs = Array.prototype.slice.call(tabsRoot.querySelectorAll('[role="tab"]'));

    function select(tab, moveFocus) {
      tabs.forEach(function (t) {
        var selected = t === tab;
        var panel = document.getElementById(t.getAttribute('aria-controls'));
        t.setAttribute('aria-selected', String(selected));
        t.tabIndex = selected ? 0 : -1;
        if (!panel) return;
        if (selected) {
          var wasHidden = panel.hidden;
          panel.hidden = false;
          if (wasHidden && !(reduceMotion && reduceMotion.matches)) {
            panel.classList.remove('is-entering');
            void panel.offsetWidth;
            panel.classList.add('is-entering');
          }
        } else {
          panel.hidden = true;
          panel.classList.remove('is-entering');
        }
      });
      if (moveFocus) tab.focus();
    }

    tabs.forEach(function (tab, i) {
      tab.addEventListener('click', function () { select(tab, false); });
      tab.addEventListener('keydown', function (e) {
        var next = null;
        if (e.key === 'ArrowRight' || e.key === 'ArrowDown') next = tabs[(i + 1) % tabs.length];
        else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') next = tabs[(i - 1 + tabs.length) % tabs.length];
        else if (e.key === 'Home') next = tabs[0];
        else if (e.key === 'End') next = tabs[tabs.length - 1];
        if (next) { e.preventDefault(); select(next, true); }
      });
    });
  }

  /* ---------- 复制 SHA256 ---------- */
  var copyBtn = document.querySelector('[data-copy]');
  if (copyBtn) {
    var status = copyBtn.parentElement ? copyBtn.parentElement.querySelector('.copy-status') : null;
    var timer = 0;

    function report(text) {
      if (!status) return;
      status.textContent = text;
      clearTimeout(timer);
      timer = setTimeout(function () { status.textContent = ''; }, 3000);
    }

    function fallbackCopy(value) {
      var area = document.createElement('textarea');
      area.value = value;
      area.setAttribute('readonly', '');
      area.style.position = 'fixed';
      area.style.opacity = '0';
      document.body.appendChild(area);
      area.select();
      var ok = false;
      try { ok = document.execCommand('copy'); } catch (err) { ok = false; }
      document.body.removeChild(area);
      return ok;
    }

    copyBtn.addEventListener('click', function () {
      var source = document.querySelector(copyBtn.getAttribute('data-copy'));
      if (!source) return;
      var value = source.textContent.trim();
      var done = function () { report('已复制到剪贴板'); };
      var fail = function () {
        if (fallbackCopy(value)) { done(); return; }
        var range = document.createRange();
        range.selectNodeContents(source);
        var sel = window.getSelection();
        if (sel) { sel.removeAllRanges(); sel.addRange(range); }
        report('无法自动复制，已选中文本，请手动复制');
      };
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(value).then(done, fail);
      } else {
        fail();
      }
    });
  }
})();
