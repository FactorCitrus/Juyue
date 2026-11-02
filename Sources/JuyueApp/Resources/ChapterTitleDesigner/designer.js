(function () {
  "use strict";

  var ELEMENT_TYPES = [
    "chapterNumber",
    "chapterName",
    "decoration",
    "backgroundImage",
    "image",
    "text",
    "box",
    "line"
  ];

  var TYPE_LABELS = {
    chapterNumber: "章节数",
    chapterName: "章节名",
    decoration: "装饰线",
    backgroundImage: "背景层",
    image: "图片",
    text: "文本",
    box: "色块",
    line: "线条"
  };

  var TEXT_TYPES = ["chapterNumber", "chapterName", "text"];
  var BOX_TYPES = ["box", "backgroundImage"];
  var IMAGE_TYPES = ["image"];
  var SOURCE_ASSET_RE = /qireader-title-asset:\/\/([A-Za-z0-9._:-]+)/g;

  var els = {};
  var moveable = null;
  var sourceDirty = false;
  var applyingSnapshot = false;
  var notifyTimer = 0;
  var history = [];
  var historyIndex = -1;
  var lastFocusedValue = "";
  var lastFocusedControl = null;

  var state = {
    schemaVersion: 1,
    canvas: {
      height: 144,
      css: {
        "background-color": "transparent",
        "background-image": "",
        "background-size": "cover",
        "background-position": "center",
        "border-radius": "0px",
        padding: "0px"
      }
    },
    elements: [],
    css: "",
    html: "",
    assets: [],
    selectedId: null
  };

  function $(id) {
    return document.getElementById(id);
  }

  function setup() {
    els.canvas = $("titleCanvas");
    els.elementList = $("elementList");
    els.assetList = $("assetList");
    els.addButtons = $("addElementButtons");
    els.propertyPanel = $("propertyPanel");
    els.selectionTitle = $("selectionTitle");
    els.status = $("statusBar");
    els.cssSource = $("cssSource");
    els.htmlSource = $("htmlSource");
    els.guideX = $("guideX");
    els.guideY = $("guideY");
    els.canvasShell = $("canvasShell");
    els.selectionHud = $("selectionHud");
    els.quickActions = $("quickActions");
    els.appShell = document.querySelector(".app-shell");

    setMobilePanel("elements");
    buildAddButtons();
    bindStaticEvents();
    loadProject(defaultProject(), { resetHistory: true });
    initializeMoveable();
    setStatus("就绪");
  }

  function defaultProject() {
    // 设计器不再内置任何预置元素 / 装饰线 / 背景层。
    // 元素全部来源于外部设置（initProject 时由 Swift 传入 htmlTemplate 或 projectJSON）。
    // 这里只保留一个空画布形状，给 normalizeProject / parseSource 当作合法的 shell。
    return {
      schemaVersion: 1,
      canvas: {
        height: 144,
        css: {
          "background-color": "transparent",
          "background-image": "",
          "background-size": "cover",
          "background-position": "center",
          "border-radius": "0px",
          padding: "0px"
        }
      },
      elements: [],
      assets: []
    };
  }

  function normalizeProject(payload) {
    var incoming = payload || {};
    if (typeof incoming.projectJSON === "string") {
      try {
        incoming = JSON.parse(incoming.projectJSON);
      } catch (err) {
        reportError("项目 JSON 无法解析：" + err.message);
        incoming = {};
      }
    }
    if (incoming.project && typeof incoming.project === "object") {
      incoming = incoming.project;
    }

    var base = defaultProject();
    var hasIncomingElements = Array.isArray(incoming.elements) && incoming.elements.length > 0;
    var project = {
      schemaVersion: incoming.schemaVersion || 1,
      canvas: mergeCanvas(base.canvas, incoming.canvas || {
        height: incoming.canvasHeight || incoming.htmlHeight
      }),
      elements: hasIncomingElements ? incoming.elements.map(normalizeElement) : base.elements,
      css: typeof incoming.css === "string" ? incoming.css : "",
      html: typeof incoming.html === "string" ? incoming.html : "",
      assets: normalizeAssets(incoming.assets || incoming.assetList || []),
      selectedId: incoming.selectedId || null
    };

    if (incoming.htmlTemplate && (!hasIncomingElements || (!project.html && !project.css))) {
      parseTemplateIntoProject(incoming.htmlTemplate, project);
    }

    return project;
  }

  function mergeCanvas(baseCanvas, canvas) {
    var css = sanitizedCanvasCSS(Object.assign({}, baseCanvas.css, canvas && canvas.css ? canvas.css : {}));
    var height = clampNumber(canvas && canvas.height, 80, 360, baseCanvas.height);
    return { height: height, css: css };
  }

  function sanitizedCanvasCSS(css) {
    var clean = Object.assign({}, css || {});
    ["height", "position", "width", "overflow", "box-sizing"].forEach(function (key) {
      delete clean[key];
    });
    return clean;
  }

  function normalizeElement(element) {
    var type = ELEMENT_TYPES.indexOf(element.type) >= 0 ? element.type : "text";
    var css = Object.assign({}, defaultCSSForType(type), element.css || {});
    return {
      id: String(element.id || uniqueId(type)),
      type: type,
      selector: element.selector || selectorFor(type),
      locked: Boolean(element.locked),
      visible: element.visible !== false,
      content: element.content == null ? defaultContentForType(type) : String(element.content),
      assetId: element.assetId || "",
      css: css
    };
  }

  function normalizeAssets(assets) {
    return assets.map(function (asset) {
      var id = String(asset.id || asset.assetId || asset.name || uniqueId("asset"));
      return {
        id: id,
        name: asset.name || id,
        url: asset.url || asset.src || asset.href || "qireader-title-asset://" + id,
        width: asset.width || null,
        height: asset.height || null
      };
    });
  }

  function loadProject(project, options) {
    state.schemaVersion = project.schemaVersion || 1;
    state.canvas = mergeCanvas(defaultProject().canvas, project.canvas || {});
    state.elements = (project.elements || []).map(normalizeElement);
    state.assets = normalizeAssets(project.assets || []);
    state.selectedId = project.selectedId || (state.elements[1] && state.elements[1].id) || null;
    sourceDirty = Boolean(project.sourceDirty);
    renderAll();
    syncSourceFromProject();
    if (options && options.resetHistory) {
      history = [];
      historyIndex = -1;
      pushHistory("init");
    }
  }

  function buildAddButtons() {
    var ADDABLE = ["chapterNumber", "chapterName", "text", "decoration", "line", "box", "image"];
    ADDABLE.forEach(function (type) {
      var button = document.createElement("button");
      button.type = "button";
      button.title = "添加" + TYPE_LABELS[type];
      button.innerHTML = svgIconForType(type) + '<span></span>';
      button.querySelector("span").textContent = TYPE_LABELS[type];
      button.addEventListener("click", function () {
        mutate(function () {
          var element = createElement(type);
          state.elements.push(element);
          state.selectedId = element.id;
        }, "添加" + TYPE_LABELS[type]);
        // 切到样式面板，方便立刻编辑
        setMobilePanel("style");
      });
      els.addButtons.appendChild(button);
    });
  }

  function setMobilePanel(name) {
    if (!els.appShell) els.appShell = document.querySelector(".app-shell");
    if (els.appShell) els.appShell.dataset.mobilePanel = name;
    // 兼容旧 CSS：同时写到 body
    document.body.dataset.mobilePanel = name;
    document.querySelectorAll("[data-mobile-tab]").forEach(function (tab) {
      var active = tab.dataset.mobileTab === name;
      tab.classList.toggle("active", active);
      tab.setAttribute("aria-selected", active ? "true" : "false");
    });
  }

  var TYPE_ICON_PATHS = {
    chapterNumber: '<text x="12" y="16" text-anchor="middle" font-family="-apple-system,SF Pro Text,Helvetica" font-size="13" font-weight="700" fill="currentColor">12</text>',
    chapterName: '<path d="M5 6h14M5 12h10M5 18h14" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
    text: '<path d="M6 6h12M12 6v12M9 18h6" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
    decoration: '<path d="M3 12h7M14 12h7M11 12h2" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
    line: '<path d="M3 12h18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>',
    box: '<rect x="4" y="6" width="16" height="12" rx="2.4" fill="none" stroke="currentColor" stroke-width="1.7"/>',
    image: '<rect x="3" y="5" width="18" height="14" rx="2" fill="none" stroke="currentColor" stroke-width="1.7"/><circle cx="8.5" cy="10.5" r="1.5" fill="currentColor"/><path d="M4 17l5-5 3 3 3-4 5 6" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round"/>',
    backgroundImage: '<rect x="3" y="5" width="18" height="14" rx="2" fill="none" stroke="currentColor" stroke-width="1.7"/><path d="M4 17l5-5 3 3 3-4 5 6" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round"/>'
  };

  function svgIconForType(type) {
    var inner = TYPE_ICON_PATHS[type] || TYPE_ICON_PATHS.text;
    return '<svg viewBox="0 0 24 24" aria-hidden="true">' + inner + '</svg>';
  }

  function svg(name) {
    var paths = {
      lock: '<rect x="5" y="11" width="14" height="9" rx="2" fill="none" stroke="currentColor" stroke-width="1.7"/><path d="M8 11V8a4 4 0 0 1 8 0v3" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/>',
      unlock: '<rect x="5" y="11" width="14" height="9" rx="2" fill="none" stroke="currentColor" stroke-width="1.7"/><path d="M8 11V8a4 4 0 0 1 7.5-1.5" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/>',
      eye: '<path d="M2 12s3.5-6 10-6 10 6 10 6-3.5 6-10 6S2 12 2 12z" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round"/><circle cx="12" cy="12" r="2.4" fill="none" stroke="currentColor" stroke-width="1.7"/>',
      eyeOff: '<path d="M3 3l18 18M10.6 6.3A11 11 0 0 1 12 6c6.5 0 10 6 10 6a14 14 0 0 1-3.5 4.2M6 8.2A14 14 0 0 0 2 12s3.5 6 10 6a10 10 0 0 0 4.4-1" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/>'
    };
    return '<svg viewBox="0 0 24 24" aria-hidden="true">' + (paths[name] || '') + '</svg>';
  }

  function bindStaticEvents() {
    document.addEventListener("dragstart", function (event) {
      if (event.target && event.target.closest && event.target.closest(".editor-canvas")) {
        event.preventDefault();
      }
    });

    document.addEventListener("contextmenu", function (event) {
      if (event.target && event.target.closest && event.target.closest(".editor-canvas, .canvas-shell, .moveable-control-box")) {
        event.preventDefault();
      }
    });

    document.addEventListener("click", function (event) {
      var target = event.target && event.target.closest ? event.target.closest("[data-action], [data-align]") : event.target;
      var action = target && target.dataset ? target.dataset.action : "";
      var align = target && target.dataset ? target.dataset.align : "";
      if (action) {
        handleAction(action);
      }
      if (align) {
        alignSelected(align);
      }
    });

    document.addEventListener("focusin", function (event) {
      if (isCommitControl(event.target)) {
        lastFocusedControl = event.target;
        lastFocusedValue = event.target.value || "";
      }
    });

    document.querySelectorAll("[data-mobile-tab]").forEach(function (button) {
      button.addEventListener("click", function () {
        setMobilePanel(button.dataset.mobileTab);
      });
    });

    els.canvas.addEventListener("pointerdown", function (event) {
      if (event.target === els.canvas) {
        event.preventDefault();
        selectElement(null);
      }
    });

    els.cssSource.addEventListener("input", function () {
      sourceDirty = true;
      state.css = els.cssSource.value;
      setStatus("源码已修改，点击同步后才会更新可视化画布");
    });
    els.htmlSource.addEventListener("input", function () {
      sourceDirty = true;
      state.html = els.htmlSource.value;
      setStatus("源码已修改，点击同步后才会更新可视化画布");
    });

    window.addEventListener("keydown", function (event) {
      if (event.target && ["INPUT", "TEXTAREA", "SELECT"].indexOf(event.target.tagName) >= 0) return;
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "z") {
        event.preventDefault();
        if (event.shiftKey) redo(); else undo();
      } else if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "d") {
        event.preventDefault();
        duplicateSelected();
      } else if (event.key === "Backspace" || event.key === "Delete") {
        event.preventDefault();
        deleteSelected();
      }
    });

    window.addEventListener("resize", function () {
      updateMoveableTarget();
    });

    window.addEventListener("scroll", function () {
      updateMoveableTarget();
    }, true);
  }

  function initializeMoveable() {
    var MoveableCtor = window.Moveable && (window.Moveable.default || window.Moveable);
    if (!MoveableCtor) {
      reportError("Moveable 未加载，拖拽能力不可用");
      return;
    }
    moveable = new MoveableCtor(document.body, {
      target: null,
      draggable: true,
      resizable: true,
      rotatable: true,
      snappable: true,
      snapThreshold: 6,
      snapGap: true,
      snapCenter: true,
      snapElement: true,
      snapVertical: true,
      snapHorizontal: true,
      bounds: getMoveableBounds(),
      origin: false,
      throttleDrag: 0,
      throttleResize: 0,
      throttleRotate: 1,
      renderDirections: ["nw", "n", "ne", "w", "e", "sw", "s", "se"]
    });

    moveable
      .on("dragStart", function (event) {
        var element = selectedElement();
        if (!element || element.locked) {
          event.stop();
          return;
        }
        var rect = domForElement(element).getBoundingClientRect();
        var canvasRect = els.canvas.getBoundingClientRect();
        event.datas.startLeft = rect.left - canvasRect.left;
        event.datas.startTop = rect.top - canvasRect.top;
        event.datas.startWidth = rect.width;
        event.datas.startHeight = rect.height;
        moveable.bounds = getMoveableBounds();
      })
      .on("drag", function (event) {
        var element = selectedElement();
        if (!element) return;
        var xy = event.beforeTranslate || event.translate || [0, 0];
        var next = snapPosition(event.datas.startLeft + xy[0], event.datas.startTop + xy[1], element);
        setElementPixels(element, { left: next.left, top: next.top });
        showGuides(next.guides);
      })
      .on("dragEnd", function () {
        hideGuides();
        commit("移动元素");
      })
      .on("resizeStart", function (event) {
        var element = selectedElement();
        if (!element || element.locked) {
          event.stop();
          return;
        }
        var rect = domForElement(element).getBoundingClientRect();
        var canvasRect = els.canvas.getBoundingClientRect();
        event.datas.startLeft = rect.left - canvasRect.left;
        event.datas.startTop = rect.top - canvasRect.top;
        event.datas.startWidth = rect.width;
        event.datas.startHeight = rect.height;
        moveable.bounds = getMoveableBounds();
      })
      .on("resize", function (event) {
        var element = selectedElement();
        if (!element) return;
        var xy = event.drag && (event.drag.beforeTranslate || event.drag.translate) || [0, 0];
        var payload = {
          left: event.datas.startLeft + xy[0],
          top: event.datas.startTop + xy[1],
          width: event.width
        };
        if (!isTextElement(element)) {
          payload.height = event.height;
        }
        setElementPixels(element, payload);
      })
      .on("resizeEnd", function () {
        commit("缩放元素");
      })
      .on("rotate", function (event) {
        var element = selectedElement();
        if (!element || element.locked) return;
        element.css.transform = "rotate(" + round(event.beforeRotate || 0, 1) + "deg)";
        applyElementStyle(element);
      })
      .on("rotateEnd", function () {
        commit("旋转元素");
      });
  }

  function handleAction(action) {
    if (action === "undo") undo();
    if (action === "redo") redo();
    if (action === "duplicate") duplicateSelected();
    if (action === "delete") deleteSelected();
    if (action === "lock") toggleLock();
    if (action === "hide") toggleVisible();
    if (action === "bring-forward") nudgeZ(1);
    if (action === "send-backward") nudgeZ(-1);
    if (action === "center-selected") centerSelected();
    if (action === "fit-width") fitWidthSelected();
    if (action === "reset-transform") resetSelectedTransform();
    if (action === "clear-canvas-background") clearCanvasBackground();
    if (action === "select-canvas") selectElement(null);
    if (action === "request-import-photos") postSwift("requestImportImageFromPhotos", {});
    if (action === "request-import-files") postSwift("requestImportImageFromFiles", {});
    if (action === "sync-source") syncSourceToVisual();
    if (action === "validate") validateExport(true);
  }

  function renderAll() {
    applyCanvasStyle();
    renderCanvasElements();
    renderElementList();
    renderAssetList();
    renderProperties();
    updateMoveableTarget();
  }

  function applyCanvasStyle() {
    els.canvas.style.height = state.canvas.height + "px";
    applyStyleMap(els.canvas, sanitizedCanvasCSS(state.canvas.css || {}));
    els.canvas.style.position = "relative";
    els.canvas.style.width = "100%";
    els.canvas.style.overflow = "hidden";
  }

  function renderCanvasElements() {
    els.canvas.innerHTML = "";
    state.elements.forEach(function (element) {
      var node = createDOMForElement(element);
      els.canvas.appendChild(node);
      applyElementStyle(element);
    });
  }

  function createDOMForElement(element) {
    var node;
    if (element.type === "image") {
      node = document.createElement("img");
      node.alt = element.content || TYPE_LABELS[element.type];
      node.src = assetURL(element.assetId);
    } else if (element.type === "chapterName") {
      node = document.createElement("h2");
      node.textContent = element.content || "章节名";
    } else if (element.type === "chapterNumber") {
      node = document.createElement("p");
      node.textContent = element.content || "章节数";
    } else {
      node = document.createElement("div");
      node.textContent = isTextElement(element) ? element.content : "";
    }
    node.dataset.id = element.id;
    node.dataset.qrId = element.id;
    node.dataset.qrType = element.type;
    node.draggable = false;
    node.setAttribute("draggable", "false");
    node.className = classesForElement(element);
    node.addEventListener("dragstart", function (event) {
      event.preventDefault();
    });
    node.addEventListener("contextmenu", function (event) {
      event.preventDefault();
    });
    node.addEventListener("pointerdown", function (event) {
      event.preventDefault();
      event.stopPropagation();
      selectElement(element.id);
    });
    return node;
  }

  function classesForElement(element) {
    var selectorClass = selectorClassName(element.selector);
    return ["qr-design-element", selectorClass, element.selected ? "selected" : "", element.locked ? "locked" : "", element.visible ? "" : "hidden-in-editor"].filter(Boolean).join(" ");
  }

  function applyElementStyle(element) {
    var node = domForElement(element);
    if (!node) return;
    node.className = classesForElement(element) + (state.selectedId === element.id ? " selected" : "");
    node.style.display = element.visible ? "" : "none";
    applyStyleMap(node, element.css || {});
    node.style.position = "absolute";
    node.style.boxSizing = "border-box";
    node.style.webkitUserDrag = "none";
    node.style.webkitTouchCallout = "none";
    node.style.userSelect = "none";
    node.style.touchAction = "none";
    if (element.type === "image") {
      node.src = assetURL(element.assetId);
    }
    if (element.type === "backgroundImage") {
      var bg = element.assetId ? "url(\"" + assetURL(element.assetId) + "\")" : element.css["background-image"];
      if (bg) node.style.backgroundImage = bg;
    }
  }

  function applyStyleMap(node, css) {
    Object.keys(css || {}).forEach(function (key) {
      if (css[key] == null) return;
      node.style.setProperty(key, String(css[key]));
    });
  }

  function renderElementList() {
    els.elementList.innerHTML = "";
    var sorted = state.elements.slice().sort(function (a, b) {
      return numberCSS(b, "z-index", 0) - numberCSS(a, "z-index", 0);
    });
    if (!sorted.length) {
      var empty = document.createElement("div");
      empty.className = "asset-empty";
      empty.textContent = "还没有元素，点上方按钮添加";
      els.elementList.appendChild(empty);
      return;
    }
    sorted.forEach(function (element) {
      var row = document.createElement("div");
      row.className = "element-row" + (state.selectedId === element.id ? " active" : "") + (element.locked ? " locked" : "");
      row.setAttribute("role", "button");
      row.tabIndex = 0;

      var icon = document.createElement("span");
      icon.className = "element-icon";
      icon.innerHTML = svgIconForType(element.type);

      var meta = document.createElement("span");
      meta.className = "element-meta";
      var name = document.createElement("span");
      name.className = "element-name";
      name.textContent = (isTextElement(element) && element.content)
        ? (TYPE_LABELS[element.type] + "：" + element.content)
        : TYPE_LABELS[element.type];
      var sub = document.createElement("span");
      sub.className = "element-sub";
      var subBits = ["层 " + (element.css["z-index"] || 0)];
      if (element.locked) subBits.push("已锁定");
      if (!element.visible) subBits.push("已隐藏");
      sub.textContent = subBits.join(" · ");
      meta.appendChild(name);
      meta.appendChild(sub);

      var actions = document.createElement("span");
      actions.className = "row-actions";
      var visBtn = document.createElement("button");
      visBtn.type = "button";
      visBtn.title = element.visible ? "隐藏" : "显示";
      visBtn.innerHTML = svg(element.visible ? "eye" : "eyeOff");
      if (!element.visible) visBtn.classList.add("active");
      visBtn.addEventListener("click", function (e) {
        e.stopPropagation();
        selectElement(element.id);
        toggleVisible();
      });
      var lockBtn = document.createElement("button");
      lockBtn.type = "button";
      lockBtn.title = element.locked ? "解锁" : "锁定";
      lockBtn.innerHTML = svg(element.locked ? "lock" : "unlock");
      if (element.locked) lockBtn.classList.add("active");
      lockBtn.addEventListener("click", function (e) {
        e.stopPropagation();
        selectElement(element.id);
        toggleLock();
      });
      actions.appendChild(visBtn);
      actions.appendChild(lockBtn);

      row.appendChild(icon);
      row.appendChild(meta);
      row.appendChild(actions);
      row.addEventListener("click", function () { selectElement(element.id); });
      row.addEventListener("keydown", function (e) {
        if (e.key === "Enter" || e.key === " ") { e.preventDefault(); selectElement(element.id); }
      });
      els.elementList.appendChild(row);
    });
  }

  function renderAssetList() {
    els.assetList.innerHTML = "";
    if (!state.assets.length) {
      var empty = document.createElement("div");
      empty.className = "asset-empty";
      empty.textContent = "还没有图片，点右上方「从相册」或「从文件」添加";
      els.assetList.appendChild(empty);
      return;
    }
    state.assets.forEach(function (asset) {
      var row = document.createElement("div");
      row.className = "asset-row";

      var thumb = document.createElement("span");
      thumb.className = "asset-thumb";
      if (asset.url) {
        thumb.style.backgroundImage = 'url("' + asset.url + '")';
      } else {
        thumb.innerHTML = svgIconForType("image");
      }

      var meta = document.createElement("span");
      meta.className = "asset-meta";
      var name = document.createElement("span");
      name.className = "asset-name";
      name.textContent = asset.name || asset.id;
      var sub = document.createElement("span");
      sub.className = "asset-sub";
      sub.textContent = asset.id;
      meta.appendChild(name);
      meta.appendChild(sub);

      var actions = document.createElement("span");
      actions.className = "row-actions";
      var insert = document.createElement("button");
      insert.type = "button";
      insert.textContent = "插入";
      insert.addEventListener("click", function () { insertAsset(asset); });
      var bg = document.createElement("button");
      bg.type = "button";
      bg.textContent = "设为背景";
      bg.addEventListener("click", function () { setCanvasBackgroundAsset(asset); });
      var remove = document.createElement("button");
      remove.type = "button";
      remove.className = "danger";
      remove.textContent = "删除";
      remove.addEventListener("click", function () { removeAsset(asset); });
      actions.appendChild(insert);
      actions.appendChild(bg);
      actions.appendChild(remove);

      row.appendChild(thumb);
      row.appendChild(meta);
      row.appendChild(actions);
      els.assetList.appendChild(row);
    });
  }

  function renderProperties() {
    els.propertyPanel.innerHTML = "";
    var element = selectedElement();
    els.selectionTitle.textContent = element ? TYPE_LABELS[element.type] : "画布样式";
    if (els.quickActions) els.quickActions.hidden = !element;
    if (!element) {
      renderCanvasProperties();
      renderTargetCSSProperties(null);
      return;
    }
    // 位置 & 尺寸（统一在最前，最常用）
    renderLayoutProperties(element);
    if (isTextElement(element)) renderTextProperties(element);
    if (IMAGE_TYPES.indexOf(element.type) >= 0 || element.type === "backgroundImage") renderImageProperties(element);
    if (BOX_TYPES.indexOf(element.type) >= 0) renderBoxProperties(element);
    if (element.type === "line" || element.type === "decoration") renderLineProperties(element);
    renderEffectsProperties(element);
    renderTargetCSSProperties(element);
  }

  function renderLayoutProperties(element) {
    var group = fieldGroup("位置与尺寸");
    var fields = [
      stepperField("左 %", parsePercent(element.css.left, 0), function (value) {
        mutate(function () { element.css.left = clampNumber(value, -50, 150, 0) + "%"; }, "修改位置 X");
      }, { step: 1 }),
      stepperField("上 %", parsePercent(element.css.top, 0), function (value) {
        mutate(function () { element.css.top = clampNumber(value, -50, 150, 0) + "%"; }, "修改位置 Y");
      }, { step: 1 }),
      stepperField("宽 %", parsePercent(element.css.width, 50), function (value) {
        mutate(function () { element.css.width = clampNumber(value, 1, 200, 50) + "%"; }, "修改宽度");
      }, { step: 1 })
    ];
    if (!isTextElement(element)) {
      fields.push(stepperField("高 %", percentHeight(element), function (value) {
        mutate(function () { element.css.height = clampNumber(value, 1, 200, 20) + "%"; }, "修改高度");
      }, { step: 1 }));
    }
    fields.push(stepperField("旋转°", parseRotation(element.css.transform), function (value) {
      mutate(function () { element.css.transform = "rotate(" + clampNumber(value, -180, 180, 0) + "deg)"; }, "修改旋转");
    }, { step: 5 }));
    fields.push(stepperField("层级", numberCSS(element, "z-index", 0), function (value) {
      mutate(function () { element.css["z-index"] = String(Math.max(0, Math.round(value))); }, "修改层级");
    }, { step: 1, min: 0 }));
    group.appendChild(fieldGrid(fields));
    els.propertyPanel.appendChild(group);
  }

  function renderEffectsProperties(element) {
    if (element.type === "decoration" || element.type === "line") return;
    var group = fieldGroup("效果");
    group.appendChild(fieldGrid([
      rangeField("透明度", parseFloat(element.css.opacity || "1"), function (value) {
        mutate(function () { element.css.opacity = String(value); }, "修改透明度");
      }, { min: 0, max: 1, step: 0.05, format: function (v) { return Math.round(v * 100) + "%"; } }),
      inputField("阴影", "text", element.css["box-shadow"] || element.css["text-shadow"] || "", function (value) {
        mutate(function () {
          if (isTextElement(element)) element.css["text-shadow"] = value;
          else element.css["box-shadow"] = value;
        }, "修改阴影");
      }, { placeholder: "0 2px 6px rgba(0,0,0,.2)" })
    ]));
    els.propertyPanel.appendChild(group);
  }

  function renderCanvasProperties() {
    var group = fieldGroup("画布");
    group.appendChild(fieldGrid([
      stepperField("高度 px", state.canvas.height, function (value) {
        mutate(function () { state.canvas.height = clampNumber(value, 80, 360, 144); }, "修改画布高度");
      }, { step: 4, min: 80, max: 360 }),
      colorTransparentField("背景色", state.canvas.css["background-color"] || "transparent", function (value) {
        mutate(function () { state.canvas.css["background-color"] = String(value || "").trim() || "transparent"; }, "修改画布背景色");
      }),
      inputField("背景图", "text", state.canvas.css["background-image"] || "", function (value) {
        mutate(function () { state.canvas.css["background-image"] = value; }, "修改画布背景图");
      }, { placeholder: 'url("…")' }),
      inputField("圆角", "text", state.canvas.css["border-radius"] || "0px", function (value) {
        mutate(function () { state.canvas.css["border-radius"] = value || "0px"; }, "修改画布圆角");
      }),
      inputField("内边距", "text", state.canvas.css.padding || "0px", function (value) {
        mutate(function () { state.canvas.css.padding = value; }, "修改画布内边距");
      })
    ]));
    // 透明背景快捷按钮
    var clearBtn = document.createElement("button");
    clearBtn.type = "button";
    clearBtn.className = "chip";
    clearBtn.textContent = "透明背景";
    clearBtn.dataset.action = "clear-canvas-background";
    var chipRow = document.createElement("div");
    chipRow.className = "quick-actions";
    chipRow.style.marginTop = "10px";
    chipRow.appendChild(clearBtn);
    group.appendChild(chipRow);
    els.propertyPanel.appendChild(group);
  }

  function renderTargetCSSProperties(element) {
    var selector = element ? element.selector : ".qr-title-canvas";
    var css = element ? element.css : Object.assign({ height: state.canvas.height + "px" }, sanitizedCanvasCSS(state.canvas.css || {}));
    var details = document.createElement("details");
    details.className = "field-group";
    details.style.gap = "8px";
    var summary = document.createElement("summary");
    summary.className = "field-group-title";
    summary.style.cursor = "pointer";
    summary.style.listStyle = "none";
    summary.textContent = "高级：CSS 源码  " + selector;
    details.appendChild(summary);
    details.appendChild(codeTextareaField(selector, cssBlockText(selector, css), function (value) {
      applyTargetCSSText(element, value);
    }));
    els.propertyPanel.appendChild(details);
  }

  function renderTextProperties(element) {
    // 内容
    var contentGroup = fieldGroup("内容");
    contentGroup.appendChild(fieldGrid([
      textareaField("文字", element.content, function (value) {
        mutate(function () {
          element.content = value;
          var node = domForElement(element);
          if (node) node.textContent = value;
        }, "修改内容");
      })
    ]));
    els.propertyPanel.appendChild(contentGroup);

    // 字体
    var fontGroup = fieldGroup("字体");
    fontGroup.appendChild(fieldGrid([
      inputField("字体", "text", element.css["font-family"] || "", function (value) {
        mutate(function () { element.css["font-family"] = value; }, "修改字体");
      }, { placeholder: "章节名字体 / PingFang SC" }),
      stepperField("字号 px", parseFloat(element.css["font-size"]) || 16, function (value) {
        mutate(function () { element.css["font-size"] = Math.max(1, Math.round(value)) + "px"; }, "修改字号");
      }, { step: 1, min: 1 }),
      selectField("字重", element.css["font-weight"] || "400",
        [["300", "细"], ["400", "常规"], ["500", "中等"], ["600", "半粗"], ["700", "粗"], ["800", "特粗"]],
        function (value) { mutate(function () { element.css["font-weight"] = value; }, "修改字重"); }),
      segmentField("字形", element.css["font-style"] || "normal",
        [["normal", "正"], ["italic", "斜"]],
        function (value) { mutate(function () { element.css["font-style"] = value; }, "修改字形"); }),
      segmentField("对齐", element.css["text-align"] || "left",
        [["left", "左"], ["center", "中"], ["right", "右"], ["justify", "齐"]],
        function (value) { mutate(function () { element.css["text-align"] = value; }, "修改对齐"); })
    ]));
    els.propertyPanel.appendChild(fontGroup);

    // 颜色与间距
    var colorGroup = fieldGroup("颜色与间距");
    colorGroup.appendChild(fieldGrid([
      inputField("文字色", "color", colorValue(element.css.color, "#333333"), function (value) {
        mutate(function () { element.css.color = value; }, "修改颜色");
      }),
      colorTransparentField("背景", element.css["background-color"] || "transparent", function (value) {
        mutate(function () { element.css["background-color"] = value; }, "修改文字背景");
      }),
      stepperField("行高", parseFloat(element.css["line-height"]) || 1.3, function (value) {
        mutate(function () { element.css["line-height"] = String(round(value, 2)); }, "修改行高");
      }, { step: 0.05, min: 0.5, max: 4 }),
      stepperField("字距 px", parseFloat(element.css["letter-spacing"]) || 0, function (value) {
        mutate(function () { element.css["letter-spacing"] = value + "px"; }, "修改字距");
      }, { step: 0.5 }),
      inputField("内边距", "text", element.css.padding || "0px", function (value) {
        mutate(function () { element.css.padding = value || "0px"; }, "修改文字内边距");
      }),
      inputField("圆角", "text", element.css["border-radius"] || "0px", function (value) {
        mutate(function () { element.css["border-radius"] = value || "0px"; }, "修改文字圆角");
      })
    ]));
    els.propertyPanel.appendChild(colorGroup);

    // 装饰（不常用，单列）
    var decoGroup = fieldGroup("装饰");
    decoGroup.appendChild(fieldGrid([
      selectField("下划线", element.css["text-decoration-line"] || "none",
        [["none", "无"], ["underline", "下划线"], ["overline", "上划线"], ["line-through", "删除线"]],
        function (value) { mutate(function () { element.css["text-decoration-line"] = value; }, "修改文字装饰"); }),
      selectField("大小写", element.css["text-transform"] || "none",
        [["none", "无"], ["uppercase", "全大写"], ["lowercase", "全小写"], ["capitalize", "首字母"]],
        function (value) { mutate(function () { element.css["text-transform"] = value; }, "修改大小写"); }),
      inputField("描边宽", "text", element.css["-webkit-text-stroke-width"] || "0px", function (value) {
        mutate(function () { element.css["-webkit-text-stroke-width"] = value || "0px"; }, "修改描边宽");
      }),
      inputField("描边色", "color", colorValue(element.css["-webkit-text-stroke-color"], "#000000"), function (value) {
        mutate(function () { element.css["-webkit-text-stroke-color"] = value; }, "修改描边色");
      })
    ]));
    els.propertyPanel.appendChild(decoGroup);
  }

  function renderImageProperties(element) {
    var group = fieldGroup("图片");
    var options = [["", "无"]].concat(state.assets.map(function (asset) {
      return [asset.id, asset.name || asset.id];
    }));
    group.appendChild(fieldGrid([
      selectField("资源", element.assetId || "", options, function (value) {
        mutate(function () { element.assetId = value; }, "修改图片资源");
      }),
      segmentField("填充", element.css["object-fit"] || element.css["background-size"] || "cover",
        [["cover", "覆盖"], ["contain", "适应"], ["fill", "拉伸"], ["none", "原始"]],
        function (value) {
          mutate(function () {
            element.css["object-fit"] = value;
            element.css["background-size"] = value;
          }, "修改图片填充");
        }),
      inputField("位置", "text", element.css["object-position"] || element.css["background-position"] || "center", function (value) {
        mutate(function () {
          var position = value || "center";
          element.css["object-position"] = position;
          element.css["background-position"] = position;
        }, "修改图片位置");
      }),
      inputField("圆角", "text", element.css["border-radius"] || "0px", function (value) {
        mutate(function () { element.css["border-radius"] = value; }, "修改圆角");
      }),
      selectField("混合", element.css["mix-blend-mode"] || "normal",
        [["normal", "正常"], ["multiply", "正片叠底"], ["screen", "滤色"], ["overlay", "叠加"], ["soft-light", "柔光"], ["luminosity", "明度"]],
        function (value) { mutate(function () { element.css["mix-blend-mode"] = value; }, "修改图片混合模式"); }),
      inputField("滤镜", "text", element.css.filter || "", function (value) {
        mutate(function () { element.css.filter = value; }, "修改图片滤镜");
      }, { placeholder: "blur(2px) brightness(.9)" })
    ]));
    els.propertyPanel.appendChild(group);

    var borderGroup = fieldGroup("边框");
    borderGroup.appendChild(fieldGrid([
      inputField("颜色", "color", colorValue(element.css["border-color"], "#000000"), function (value) {
        mutate(function () {
          element.css["border-color"] = value;
          element.css["border-style"] = element.css["border-style"] || "solid";
        }, "修改图片边框色");
      }),
      stepperField("宽度 px", parseFloat(element.css["border-width"]) || 0, function (value) {
        mutate(function () {
          element.css["border-width"] = Math.max(0, value) + "px";
          element.css["border-style"] = element.css["border-style"] || "solid";
        }, "修改图片边框宽");
      }, { step: 1, min: 0 }),
      selectField("样式", element.css["border-style"] || "solid",
        [["solid", "实线"], ["dashed", "虚线"], ["dotted", "点线"], ["none", "无"]],
        function (value) { mutate(function () { element.css["border-style"] = value; }, "修改图片边框样式"); })
    ]));
    els.propertyPanel.appendChild(borderGroup);
  }

  function renderBoxProperties(element) {
    var group = fieldGroup("色块");
    group.appendChild(fieldGrid([
      colorTransparentField("背景", element.css["background-color"] || "#ffffff", function (value) {
        mutate(function () { element.css["background-color"] = value; }, "修改背景色");
      }),
      inputField("圆角", "text", element.css["border-radius"] || "0px", function (value) {
        mutate(function () { element.css["border-radius"] = value; }, "修改圆角");
      })
    ]));
    els.propertyPanel.appendChild(group);

    var borderGroup = fieldGroup("边框");
    borderGroup.appendChild(fieldGrid([
      inputField("颜色", "color", colorValue(element.css["border-color"], "#000000"), function (value) {
        mutate(function () {
          element.css["border-color"] = value;
          element.css["border-style"] = element.css["border-style"] || "solid";
        }, "修改边框色");
      }),
      stepperField("宽度 px", parseFloat(element.css["border-width"]) || 0, function (value) {
        mutate(function () {
          element.css["border-width"] = Math.max(0, value) + "px";
          element.css["border-style"] = element.css["border-style"] || "solid";
        }, "修改边框宽");
      }, { step: 1, min: 0 }),
      selectField("样式", element.css["border-style"] || "solid",
        [["solid", "实线"], ["dashed", "虚线"], ["dotted", "点线"], ["none", "无"]],
        function (value) { mutate(function () { element.css["border-style"] = value; }, "修改边框样式"); })
    ]));
    els.propertyPanel.appendChild(borderGroup);
  }

  function renderLineProperties(element) {
    var group = fieldGroup("线条");
    group.appendChild(fieldGrid([
      inputField("颜色", "color", colorValue(element.css["background-color"], "#c9aa68"), function (value) {
        mutate(function () { element.css["background-color"] = value; }, "修改线条颜色");
      }),
      stepperField("粗细 px", parseFloat(element.css.height) || 2, function (value) {
        mutate(function () { element.css.height = Math.max(1, Math.round(value)) + "px"; }, "修改线条粗细");
      }, { step: 1, min: 1 }),
      stepperField("长度 %", parsePercent(element.css.width, 30), function (value) {
        mutate(function () { element.css.width = clampNumber(value, 1, 200, 30) + "%"; }, "修改线条长度");
      }, { step: 1, min: 1 }),
      stepperField("圆角 px", parseFloat(element.css["border-radius"]) || 0, function (value) {
        mutate(function () { element.css["border-radius"] = Math.max(0, Math.round(value)) + "px"; }, "修改线条圆角");
      }, { step: 1, min: 0 }),
      rangeField("透明度", parseFloat(element.css.opacity || "1"), function (value) {
        mutate(function () { element.css.opacity = String(value); }, "修改透明度");
      }, { min: 0, max: 1, step: 0.05, format: function (v) { return Math.round(v * 100) + "%"; } })
    ]));
    els.propertyPanel.appendChild(group);
  }

  function fieldGroup(title) {
    var group = document.createElement("div");
    group.className = "field-group";
    var heading = document.createElement("div");
    heading.className = "field-group-title";
    heading.textContent = title;
    group.appendChild(heading);
    return group;
  }

  function fieldGrid(fields) {
    var grid = document.createElement("div");
    grid.className = "field-grid";
    fields.forEach(function (field) { grid.appendChild(field); });
    return grid;
  }

  function actionStrip(items) {
    var strip = document.createElement("div");
    strip.className = "action-strip";
    items.forEach(function (item) {
      var button = document.createElement("button");
      button.type = "button";
      button.dataset.action = item[1];
      button.textContent = item[0];
      strip.appendChild(button);
    });
    return strip;
  }

  function inputField(label, type, value, onChange, attrs) {
    var wrap = document.createElement("div");
    wrap.className = "field";
    var id = uniqueId("field");
    var labelNode = document.createElement("label");
    labelNode.setAttribute("for", id);
    labelNode.textContent = label;
    var input = document.createElement("input");
    input.id = id;
    input.type = type;
    input.value = value == null ? "" : value;
    Object.keys(attrs || {}).forEach(function (key) {
      if (key === "placeholder") input.placeholder = attrs[key];
      else input.setAttribute(key, attrs[key]);
    });
    input.addEventListener("change", function () { onChange(input.value); });
    input.addEventListener("focus", function () { lastFocusedValue = input.value; });
    wrap.appendChild(labelNode);
    wrap.appendChild(input);
    return wrap;
  }

  function stepperField(label, value, onChange, opts) {
    opts = opts || {};
    var step = opts.step || 1;
    var min = opts.min == null ? -Infinity : opts.min;
    var max = opts.max == null ? Infinity : opts.max;
    var wrap = document.createElement("div");
    wrap.className = "field";
    var labelNode = document.createElement("label");
    labelNode.textContent = label;
    var control = document.createElement("div");
    control.className = "stepper";
    var minus = document.createElement("button");
    minus.type = "button";
    minus.textContent = "−";
    var input = document.createElement("input");
    input.type = "text";
    input.inputMode = "decimal";
    input.value = String(round(Number(value) || 0, 2));
    var plus = document.createElement("button");
    plus.type = "button";
    plus.textContent = "+";
    function apply(v) {
      var n = Number(v);
      if (!Number.isFinite(n)) n = Number(value) || 0;
      n = Math.min(max, Math.max(min, n));
      input.value = String(round(n, 2));
      onChange(n);
    }
    minus.addEventListener("click", function () { apply((Number(input.value) || 0) - step); });
    plus.addEventListener("click", function () { apply((Number(input.value) || 0) + step); });
    input.addEventListener("change", function () { apply(input.value); });
    input.addEventListener("focus", function () { lastFocusedValue = input.value; });
    control.appendChild(minus);
    control.appendChild(input);
    control.appendChild(plus);
    wrap.appendChild(labelNode);
    wrap.appendChild(control);
    return wrap;
  }

  function rangeField(label, value, onChange, opts) {
    opts = opts || {};
    var wrap = document.createElement("div");
    wrap.className = "field wide";
    var labelNode = document.createElement("label");
    var current = document.createElement("span");
    current.style.cssText = "float:right;color:var(--muted);font-weight:500;";
    var fmt = opts.format || function (v) { return String(v); };
    current.textContent = fmt(value);
    labelNode.textContent = label;
    labelNode.appendChild(current);
    var input = document.createElement("input");
    input.type = "range";
    input.min = String(opts.min == null ? 0 : opts.min);
    input.max = String(opts.max == null ? 1 : opts.max);
    input.step = String(opts.step == null ? 0.01 : opts.step);
    input.value = String(value);
    input.addEventListener("input", function () {
      current.textContent = fmt(Number(input.value));
    });
    input.addEventListener("change", function () {
      onChange(Number(input.value));
    });
    wrap.appendChild(labelNode);
    wrap.appendChild(input);
    return wrap;
  }

  function segmentField(label, value, options, onChange) {
    var wrap = document.createElement("div");
    wrap.className = "field";
    var labelNode = document.createElement("label");
    labelNode.textContent = label;
    var segment = document.createElement("div");
    segment.className = "segment";
    options.forEach(function (option) {
      var optionValue = Array.isArray(option) ? option[0] : option;
      var optionLabel = Array.isArray(option) ? option[1] : option;
      var btn = document.createElement("button");
      btn.type = "button";
      btn.textContent = optionLabel;
      if (String(optionValue) === String(value)) btn.classList.add("active");
      btn.addEventListener("click", function () {
        Array.prototype.forEach.call(segment.children, function (child) { child.classList.remove("active"); });
        btn.classList.add("active");
        onChange(optionValue);
      });
      segment.appendChild(btn);
    });
    wrap.appendChild(labelNode);
    wrap.appendChild(segment);
    return wrap;
  }

  function colorTransparentField(label, value, onChange) {
    var wrap = document.createElement("div");
    wrap.className = "field color-transparent-field";
    var id = uniqueId("field");
    var labelNode = document.createElement("label");
    labelNode.setAttribute("for", id);
    labelNode.textContent = label;

    var controls = document.createElement("div");
    controls.className = "color-transparent-control";

    var input = document.createElement("input");
    input.id = id;
    input.type = "color";
    input.value = colorValue(value, "#ffffff");
    input.addEventListener("change", function () { onChange(input.value); });

    var transparent = document.createElement("button");
    transparent.type = "button";
    transparent.textContent = "透明";
    transparent.className = isTransparentColor(value) ? "active" : "";
    transparent.addEventListener("click", function () { onChange("transparent"); });

    controls.appendChild(input);
    controls.appendChild(transparent);
    wrap.appendChild(labelNode);
    wrap.appendChild(controls);
    return wrap;
  }

  function textareaField(label, value, onChange) {
    var wrap = document.createElement("div");
    wrap.className = "field wide";
    var id = uniqueId("field");
    var labelNode = document.createElement("label");
    labelNode.setAttribute("for", id);
    labelNode.textContent = label;
    var input = document.createElement("textarea");
    input.id = id;
    input.value = value == null ? "" : value;
    input.addEventListener("focus", function () { lastFocusedValue = input.value; });
    input.addEventListener("input", function () {
      var element = selectedElement();
      if (element) {
        element.content = input.value;
        var node = domForElement(element);
        if (node) node.textContent = input.value;
      }
    });
    input.addEventListener("change", function () {
      if (input.value !== lastFocusedValue) onChange(input.value);
    });
    wrap.appendChild(labelNode);
    wrap.appendChild(input);
    return wrap;
  }

  function codeTextareaField(label, value, onChange) {
    var wrap = document.createElement("div");
    wrap.className = "field wide code-field";
    var id = uniqueId("field");
    var labelNode = document.createElement("label");
    labelNode.setAttribute("for", id);
    labelNode.textContent = label;
    var input = document.createElement("textarea");
    input.id = id;
    input.spellcheck = false;
    input.value = value == null ? "" : value;
    input.addEventListener("focus", function () { lastFocusedValue = input.value; });
    input.addEventListener("change", function () {
      if (input.value !== lastFocusedValue) onChange(input.value);
    });
    wrap.appendChild(labelNode);
    wrap.appendChild(input);
    return wrap;
  }

  function selectField(label, value, options, onChange) {
    var wrap = document.createElement("div");
    wrap.className = "field";
    var id = uniqueId("field");
    var labelNode = document.createElement("label");
    labelNode.setAttribute("for", id);
    labelNode.textContent = label;
    var select = document.createElement("select");
    select.id = id;
    options.forEach(function (option) {
      var optionValue = Array.isArray(option) ? option[0] : option;
      var optionLabel = Array.isArray(option) ? option[1] : (option || "无");
      var opt = document.createElement("option");
      opt.value = optionValue;
      opt.textContent = optionLabel;
      select.appendChild(opt);
    });
    select.value = value == null ? "" : value;
    select.addEventListener("change", function () { onChange(select.value); });
    wrap.appendChild(labelNode);
    wrap.appendChild(select);
    return wrap;
  }

  function selectElement(id) {
    state.selectedId = id;
    renderElementList();
    renderProperties();
    updateSelectionClass();
    updateMoveableTarget();
  }

  function updateSelectionClass() {
    state.elements.forEach(function (element) {
      var node = domForElement(element);
      if (!node) return;
      node.classList.toggle("selected", state.selectedId === element.id);
    });
  }

  function updateMoveableTarget() {
    if (!moveable) return;
    var element = selectedElement();
    if (!element || element.locked || !element.visible) {
      moveable.target = null;
      updateSelectionHud();
      return;
    }
    moveable.target = domForElement(element);
    moveable.draggable = !element.locked;
    moveable.resizable = !element.locked;
    moveable.rotatable = !element.locked;
    moveable.bounds = getMoveableBounds();
    moveable.verticalGuidelines = canvasVerticalGuides();
    moveable.horizontalGuidelines = canvasHorizontalGuides();
    moveable.updateRect();
    updateSelectionHud();
  }

  function updateSelectionHud() {
    if (!els.selectionHud) return;
    var element = selectedElement();
    if (!element) {
      els.selectionHud.hidden = true;
      return;
    }
    els.selectionHud.hidden = false;
    var lockBtn = els.selectionHud.querySelector('[data-action="lock"]');
    var hideBtn = els.selectionHud.querySelector('[data-action="hide"]');
    var dupBtn = els.selectionHud.querySelector('[data-action="duplicate"]');
    var delBtn = els.selectionHud.querySelector('[data-action="delete"]');
    if (lockBtn) {
      lockBtn.classList.toggle("active", !!element.locked);
      var lockLabel = lockBtn.querySelector("span");
      if (lockLabel) lockLabel.textContent = element.locked ? "解锁" : "锁定";
    }
    if (hideBtn) {
      hideBtn.classList.toggle("active", !element.visible);
      var hideLabel = hideBtn.querySelector("span");
      if (hideLabel) hideLabel.textContent = element.visible ? "隐藏" : "显示";
    }
    if (dupBtn) dupBtn.disabled = !!element.locked;
    if (delBtn) delBtn.disabled = !!element.locked;
  }

  function canvasVerticalGuides() {
    var rect = els.canvas.getBoundingClientRect();
    return [rect.left, rect.left + rect.width / 2, rect.right];
  }

  function canvasHorizontalGuides() {
    var rect = els.canvas.getBoundingClientRect();
    return [rect.top, rect.top + rect.height / 2, rect.bottom];
  }

  function getMoveableBounds() {
    if (!els.canvas) return undefined;
    var rect = els.canvas.getBoundingClientRect();
    if (!rect.width || !rect.height) return undefined;
    return {
      left: rect.left,
      top: rect.top,
      right: rect.right,
      bottom: rect.bottom
    };
  }

  function selectedElement() {
    return state.elements.find(function (element) { return element.id === state.selectedId; }) || null;
  }

  function domForElement(element) {
    return element ? els.canvas.querySelector('[data-id="' + cssEscape(element.id) + '"]') : null;
  }

  function createElement(type, asset) {
    var element = {
      id: uniqueId(type),
      type: type,
      selector: selectorFor(type),
      locked: false,
      visible: true,
      content: defaultContentForType(type),
      assetId: asset ? asset.id : "",
      css: defaultCSSForType(type)
    };
    if (asset && type === "image") {
      element.content = asset.name || "图片";
    }
    return element;
  }

  function defaultCSSForType(type) {
    var z = type === "backgroundImage" ? 0 : Math.max(1, state.elements.length + 1);
    var common = {
      left: "20%",
      top: "24%",
      width: "45%",
      height: "auto",
      "z-index": String(z),
      opacity: "1",
      transform: "rotate(0deg)"
    };
    if (type === "chapterNumber" || type === "chapterName" || type === "text") {
      return Object.assign(common, {
        color: type === "chapterName" ? "#2f3633" : "#777777",
        "font-family": type === "chapterNumber" ? "章节数字体" : type === "chapterName" ? "章节名字体" : "inherit",
        "font-size": type === "chapterName" ? "24px" : "16px",
        "font-weight": type === "chapterName" ? "600" : "400",
        "line-height": "1.35",
        "letter-spacing": "0px",
        "text-align": "center",
        margin: "0",
        padding: "0px"
      });
    }
    if (type === "image") {
      return Object.assign(common, {
        width: "32%",
        height: "44%",
        "object-fit": "cover",
        "border-radius": "0px",
        "box-shadow": ""
      });
    }
    if (type === "box") {
      return Object.assign(common, {
        width: "36%",
        height: "32%",
        "background-color": "rgba(36,122,115,0.16)",
        "border-width": "0px",
        "border-style": "solid",
        "border-color": "#247a73",
        "border-radius": "6px"
      });
    }
    if (type === "line" || type === "decoration") {
      return Object.assign(common, {
        width: "30%",
        height: "2px",
        "background-color": "#c9aa68",
        "border-radius": "2px"
      });
    }
    if (type === "backgroundImage") {
      return Object.assign(common, {
        left: "0%",
        top: "0%",
        width: "100%",
        height: "100%",
        "background-color": "transparent",
        "background-image": "",
        "background-size": "cover",
        "background-position": "center"
      });
    }
    return common;
  }

  function defaultContentForType(type) {
    if (type === "chapterNumber") return "章节数";
    if (type === "chapterName") return "章节名";
    if (type === "text") return "自定义文本";
    return "";
  }

  function selectorFor(type) {
    if (type === "chapterNumber") return ".qr-title-number";
    if (type === "chapterName") return ".qr-title-name";
    if (type === "decoration") return ".qr-title-decoration-" + shortId();
    if (type === "backgroundImage") return ".qr-title-bg";
    if (type === "image") return ".qr-title-image-" + shortId();
    if (type === "box") return ".qr-title-box-" + shortId();
    if (type === "line") return ".qr-title-line-" + shortId();
    return ".qr-title-text-" + shortId();
  }

  function isTextElement(element) {
    return TEXT_TYPES.indexOf(element.type) >= 0;
  }

  function setElementPixels(element, pixels) {
    var rect = els.canvas.getBoundingClientRect();
    if (!rect.width || !rect.height) return;
    var size = elementPixelSize(element);
    var next = {
      left: pixels.left != null ? pixels.left : parsePercent(element.css.left, 0) / 100 * rect.width,
      top: pixels.top != null ? pixels.top : parsePercent(element.css.top, 0) / 100 * rect.height,
      width: pixels.width != null ? pixels.width : size.width,
      height: pixels.height != null ? pixels.height : size.height
    };
    next = clampElementPixels(next, element);
    if (pixels.left != null || pixels.width != null) element.css.left = round(next.left / rect.width * 100, 3) + "%";
    if (pixels.top != null || pixels.height != null) element.css.top = round(next.top / rect.height * 100, 3) + "%";
    if (pixels.width != null) element.css.width = round(next.width / rect.width * 100, 3) + "%";
    if (pixels.height != null && !isTextElement(element)) element.css.height = round(next.height / rect.height * 100, 3) + "%";
    applyElementStyle(element);
    updateSelectionHud();
  }

  function snapPosition(left, top, element) {
    var rect = els.canvas.getBoundingClientRect();
    var node = domForElement(element);
    var nodeRect = node.getBoundingClientRect();
    var width = nodeRect.width;
    var height = nodeRect.height;
    var guides = { x: null, y: null };
    var xs = [
      { value: 0, point: left },
      { value: rect.width / 2, point: left + width / 2 },
      { value: rect.width, point: left + width }
    ];
    var ys = [
      { value: 0, point: top },
      { value: rect.height / 2, point: top + height / 2 },
      { value: rect.height, point: top + height }
    ];
    xs.some(function (guide) {
      if (Math.abs(guide.point - guide.value) <= 6) {
        left += guide.value - guide.point;
        guides.y = guide.value;
        return true;
      }
      return false;
    });
    ys.some(function (guide) {
      if (Math.abs(guide.point - guide.value) <= 6) {
        top += guide.value - guide.point;
        guides.x = guide.value;
        return true;
      }
      return false;
    });
    var clamped = clampElementPixels({
      left: left,
      top: top,
      width: width,
      height: height
    }, element);
    if (clamped.left !== left) guides.y = null;
    if (clamped.top !== top) guides.x = null;
    left = clamped.left;
    top = clamped.top;
    return { left: left, top: top, guides: guides };
  }

  function elementPixelSize(element) {
    var rect = els.canvas.getBoundingClientRect();
    var node = domForElement(element);
    var nodeRect = node ? node.getBoundingClientRect() : null;
    return {
      width: nodeRect && nodeRect.width ? nodeRect.width : parsePercent(element.css.width, 20) / 100 * rect.width,
      height: nodeRect && nodeRect.height ? nodeRect.height : percentHeight(element) / 100 * rect.height
    };
  }

  function clampElementPixels(box, element) {
    var rect = els.canvas.getBoundingClientRect();
    var minWidth = 2;
    var minHeight = isTextElement(element) ? 1 : 1;
    var width = clampNumber(box.width, minWidth, Math.max(minWidth, rect.width), minWidth);
    var height = clampNumber(box.height, minHeight, Math.max(minHeight, rect.height), minHeight);
    var maxLeft = Math.max(0, rect.width - width);
    var maxTop = Math.max(0, rect.height - height);
    return {
      left: clampNumber(box.left, 0, maxLeft, 0),
      top: clampNumber(box.top, 0, maxTop, 0),
      width: width,
      height: height
    };
  }

  function showGuides(guides) {
    var shellRect = els.canvasShell.getBoundingClientRect();
    var canvasRect = els.canvas.getBoundingClientRect();
    if (guides && guides.x != null) {
      els.guideX.style.display = "block";
      els.guideX.style.top = (canvasRect.top - shellRect.top + guides.x) + "px";
    } else {
      els.guideX.style.display = "none";
    }
    if (guides && guides.y != null) {
      els.guideY.style.display = "block";
      els.guideY.style.left = (canvasRect.left - shellRect.left + guides.y) + "px";
    } else {
      els.guideY.style.display = "none";
    }
  }

  function hideGuides() {
    els.guideX.style.display = "none";
    els.guideY.style.display = "none";
  }

  function alignSelected(mode) {
    var element = selectedElement();
    if (!element || element.locked) return;
    mutate(function () {
      var w = parsePercent(element.css.width, 20);
      var h = percentHeight(element);
      if (mode === "left") element.css.left = "0%";
      if (mode === "center-x") element.css.left = round((100 - w) / 2, 3) + "%";
      if (mode === "right") element.css.left = round(100 - w, 3) + "%";
      if (mode === "top") element.css.top = "0%";
      if (mode === "center-y") element.css.top = round((100 - h) / 2, 3) + "%";
      if (mode === "bottom") element.css.top = round(100 - h, 3) + "%";
    }, "对齐元素");
  }

  function centerSelected() {
    var element = selectedElement();
    if (!element || element.locked) return;
    mutate(function () {
      var w = parsePercent(element.css.width, 20);
      var h = percentHeight(element);
      element.css.left = round((100 - w) / 2, 3) + "%";
      element.css.top = round((100 - h) / 2, 3) + "%";
    }, "居中元素");
  }

  function fitWidthSelected() {
    var element = selectedElement();
    if (!element || element.locked) return;
    mutate(function () {
      element.css.left = "8%";
      element.css.width = "84%";
      if (!isTextElement(element)) {
        element.css.height = element.css.height || "24%";
      }
    }, "铺满元素宽度");
  }

  function resetSelectedTransform() {
    var element = selectedElement();
    if (!element || element.locked) return;
    mutate(function () {
      element.css.transform = "rotate(0deg)";
      element.css.opacity = "1";
      element.css.margin = element.css.margin || "0";
    }, "重置元素变换");
  }

  function clearCanvasBackground() {
    mutate(function () {
      state.canvas.css["background-color"] = "transparent";
      state.canvas.css["background-image"] = "";
    }, "清空画布背景");
  }

  function percentHeight(element) {
    if (String(element.css.height || "").indexOf("%") >= 0) return parsePercent(element.css.height, 10);
    var node = domForElement(element);
    if (!node) return 10;
    return round(node.getBoundingClientRect().height / els.canvas.getBoundingClientRect().height * 100, 3);
  }

  function duplicateSelected() {
    var element = selectedElement();
    if (!element || element.locked) return;
    mutate(function () {
      var copy = JSON.parse(JSON.stringify(element));
      copy.id = uniqueId(copy.type);
      copy.selector = selectorFor(copy.type);
      copy.locked = false;
      copy.css.left = round(parsePercent(copy.css.left, 0) + 4, 3) + "%";
      copy.css.top = round(parsePercent(copy.css.top, 0) + 4, 3) + "%";
      copy.css["z-index"] = String(maxZ() + 1);
      state.elements.push(copy);
      state.selectedId = copy.id;
    }, "复制元素");
  }

  function deleteSelected() {
    var element = selectedElement();
    if (!element || element.locked) return;
    mutate(function () {
      state.elements = state.elements.filter(function (item) { return item.id !== element.id; });
      state.selectedId = state.elements[0] ? state.elements[0].id : null;
    }, "删除元素");
  }

  function toggleLock() {
    var element = selectedElement();
    if (!element) return;
    mutate(function () { element.locked = !element.locked; }, element.locked ? "解锁元素" : "锁定元素");
  }

  function toggleVisible() {
    var element = selectedElement();
    if (!element) return;
    mutate(function () { element.visible = !element.visible; }, element.visible ? "隐藏元素" : "显示元素");
  }

  function nudgeZ(delta) {
    var element = selectedElement();
    if (!element || element.locked) return;
    mutate(function () {
      element.css["z-index"] = String(Math.max(0, numberCSS(element, "z-index", 0) + delta));
    }, "调整层级");
  }

  function maxZ() {
    return state.elements.reduce(function (max, element) {
      return Math.max(max, numberCSS(element, "z-index", 0));
    }, 0);
  }

  function setCanvasBackgroundAsset(asset) {
    mutate(function () {
      state.canvas.css["background-image"] = 'url("' + assetURL(asset.id) + '")';
      var bg = state.elements.find(function (element) { return element.type === "backgroundImage"; });
      if (bg) bg.assetId = asset.id;
    }, "设置背景资源");
  }

  function insertAsset(asset) {
    var normalized = normalizeAssets([asset])[0];
    if (!state.assets.some(function (item) { return item.id === normalized.id; })) {
      state.assets.push(normalized);
    }
    mutate(function () {
      var element = createElement("image", normalized);
      element.css["z-index"] = String(maxZ() + 1);
      state.elements.push(element);
      state.selectedId = element.id;
    }, "插入图片资源");
  }

  function removeAsset(asset) {
    if (!asset || !asset.id) return;
    var existingURL = assetURL(asset.id);
    var managedURL = "qireader-title-asset://" + asset.id;
    mutate(function () {
      state.assets = state.assets.filter(function (item) { return item.id !== asset.id; });
      state.elements = state.elements.filter(function (element) {
        return !(element.type === "image" && element.assetId === asset.id);
      });
      state.elements.forEach(function (element) {
        if (element.assetId === asset.id) {
          element.assetId = "";
        }
      });
      if (state.canvas.css["background-image"] === 'url("' + existingURL + '")' ||
          state.canvas.css["background-image"] === 'url("' + managedURL + '")') {
        state.canvas.css["background-image"] = "";
      }
      var bg = state.elements.find(function (element) { return element.type === "backgroundImage" && element.assetId === asset.id; });
      if (bg) {
        bg.assetId = "";
        bg.css["background-image"] = "";
      }
      if (state.selectedId && !state.elements.some(function (element) { return element.id === state.selectedId; })) {
        state.selectedId = state.elements[0] ? state.elements[0].id : null;
      }
    }, "删除图片资源");
  }

  function mutate(fn, label) {
    fn();
    renderAll();
    commit(label);
  }

  function commit(label) {
    if (applyingSnapshot) return;
    syncSourceFromProject();
    pushHistory(label);
    notifyChanged(label);
  }

  function pushHistory(label) {
    var snapshot = JSON.stringify(projectForSave({ includeSelection: true }));
    if (history[historyIndex] === snapshot) return;
    history = history.slice(0, historyIndex + 1);
    history.push(snapshot);
    if (history.length > 100) history.shift();
    historyIndex = history.length - 1;
    setStatus(label || "已更新");
  }

  function undo() {
    if (historyIndex <= 0) return;
    historyIndex -= 1;
    restoreHistory(history[historyIndex], "撤销");
  }

  function redo() {
    if (historyIndex >= history.length - 1) return;
    historyIndex += 1;
    restoreHistory(history[historyIndex], "重做");
  }

  function restoreHistory(snapshot, label) {
    applyingSnapshot = true;
    loadProject(JSON.parse(snapshot), { resetHistory: false });
    applyingSnapshot = false;
    notifyChanged(label);
    setStatus(label);
  }

  function commitFocusedControl() {
    var active = document.activeElement;
    var control = isCommitControl(active) ? active : (isCommitControl(lastFocusedControl) ? lastFocusedControl : null);
    if (!control || !document.documentElement.contains(control)) return;
    if ("value" in control && String(control.value || "") === String(lastFocusedValue || "")) return;
    control.dispatchEvent(new Event("change", { bubbles: true }));
    lastFocusedControl = null;
    lastFocusedValue = "";
  }

  function isCommitControl(node) {
    if (!node || !node.tagName) return false;
    return ["INPUT", "TEXTAREA", "SELECT"].indexOf(node.tagName.toUpperCase()) >= 0;
  }

  function syncSourceFromProject() {
    if (sourceDirty) return;
    var css = generateCSSText();
    var html = generateHTMLText();
    state.css = css;
    state.html = html;
    els.cssSource.value = css;
    els.htmlSource.value = html;
  }

  function syncSourceToVisual() {
    try {
      var parsed = parseSource(els.cssSource.value, els.htmlSource.value);
      loadProject(parsed, { resetHistory: false });
      sourceDirty = false;
      syncSourceFromProject();
      commit("同步源码");
    } catch (err) {
      sourceDirty = true;
      state.css = els.cssSource.value;
      state.html = els.htmlSource.value;
      reportError("源码同步失败：" + err.message);
      setStatus("源码同步失败，已保留输入");
    }
  }

  function parseSource(cssText, htmlText) {
    var doc = new DOMParser().parseFromString(htmlText, "text/html");
    var canvas = doc.querySelector(".qr-title-canvas");
    if (!canvas) {
      var fallbackProject = defaultProject();
      fallbackProject.elements = [];
      fallbackProject.assets = state.assets.slice();
      parseInlineTemplateIntoProject(htmlText, fallbackProject, cssText);
      if (!fallbackProject.elements.length) throw new Error("HTML 中缺少 .qr-title-canvas");
      return fallbackProject;
    }
    var rules = parseCSSRules(cssText);
    var project = defaultProject();
    project.elements = [];
    project.assets = state.assets.slice();
    project.canvas.height = parseInt(styleValue(rules, ".qr-title-canvas", "height"), 10) || state.canvas.height || 144;
    project.canvas.css = Object.assign({}, project.canvas.css, rules[".qr-title-canvas"] || {});
    Array.prototype.slice.call(canvas.children).forEach(function (node) {
      var className = Array.prototype.slice.call(node.classList).find(function (name) { return name.indexOf("qr-title-") === 0; });
      if (!className) return;
      var selector = "." + className;
      var type = node.getAttribute("data-qr-type") || inferType(node, className);
      var id = node.getAttribute("data-qr-id") || uniqueId(type);
      var css = Object.assign({}, defaultCSSForType(type), rules[selector] || {}, parseInlineStyle(node.getAttribute("style") || ""));
      var assetId = "";
      if (node.tagName === "IMG") {
        assetId = assetIdFromURL(node.getAttribute("src") || "");
      } else {
        assetId = assetIdFromURL(css["background-image"] || "");
      }
      project.elements.push(normalizeElement({
        id: id,
        type: type,
        selector: selector,
        locked: node.getAttribute("data-qr-locked") === "true",
        visible: css.display !== "none",
        content: node.textContent || defaultContentForType(type),
        assetId: assetId,
        css: css
      }));
    });
    if (!project.elements.length) {
      parseInlineTemplateIntoProject(canvas.outerHTML, project, cssText);
    }
    project.css = cssText;
    project.html = htmlText;
    return project;
  }

  function parseTemplateIntoProject(template, project) {
    var styleMatch = template.match(/<style[^>]*>([\s\S]*?)<\/style>/i);
    var cssText = styleMatch ? styleMatch[1] : "";
    var htmlText = template.replace(/<style[^>]*>[\s\S]*?<\/style>/ig, "").trim();
    if (cssText && htmlText) {
      try {
        var parsed = parseSource(cssText, htmlText);
        project.canvas = parsed.canvas;
        project.elements = parsed.elements;
        project.css = cssText;
        project.html = htmlText;
      } catch (err) {
        parseInlineTemplateIntoProject(htmlText, project, cssText);
        if (!project.elements.length) {
          project.html = htmlText;
          project.css = cssText;
        }
      }
    } else if (htmlText) {
      parseInlineTemplateIntoProject(htmlText, project, cssText);
    }
  }

  function parseInlineTemplateIntoProject(htmlText, project, cssText) {
    var doc = new DOMParser().parseFromString(htmlText, "text/html");
    var root = doc.body && doc.body.firstElementChild;
    if (!root) return;

    var numberNode = findTextNodeContaining(root, "章节数");
    var nameNode = findTextNodeContaining(root, "章节名");
    var decorationNodes = findDecorationNodes(root, numberNode, nameNode);
    var measureTargets = {
      number: numberNode,
      name: nameNode
    };
    decorationNodes.forEach(function (node, index) {
      measureTargets["decoration" + index] = node;
    });
    var measuredLayout = measureInlineTemplateLayout(root, measureTargets, cssText);
    var elements = [];

    if (numberNode) {
      elements.push(normalizeElement({
        id: "qr-number",
        type: "chapterNumber",
        selector: ".qr-title-number",
        content: "章节数",
        css: cssFromInlineNode(
          numberNode,
          defaultCSSForType("chapterNumber"),
          measuredLayout && measuredLayout.nodes.number,
          "chapterNumber"
        )
      }));
    }
    if (nameNode) {
      elements.push(normalizeElement({
        id: "qr-name",
        type: "chapterName",
        selector: ".qr-title-name",
        content: "章节名",
        css: cssFromInlineNode(
          nameNode,
          defaultCSSForType("chapterName"),
          measuredLayout && measuredLayout.nodes.name,
          "chapterName"
        )
      }));
    }
    decorationNodes.forEach(function (decorationNode, index) {
      var decorationText = String(decorationNode.textContent || "").trim();
      var type = decorationText ? "text" : "decoration";
      var selector = index === 0 && type === "decoration"
        ? ".qr-title-decoration"
        : ".qr-title-" + type + "-" + (index + 1);
      elements.push(normalizeElement({
        id: "qr-decoration-" + index,
        type: type,
        selector: selector,
        content: decorationText,
        css: cssFromInlineNode(
          decorationNode,
          defaultCSSForType(type),
          measuredLayout && measuredLayout.nodes["decoration" + index],
          type
        )
      }));
    });

    if (!elements.length) return;
    if (measuredLayout && measuredLayout.canvasHeight) {
      project.canvas.height = measuredLayout.canvasHeight;
    }
    project.canvas.css = Object.assign({}, project.canvas.css, canvasCSSFromInlineRoot(root, {
      flattenLayout: Boolean(measuredLayout),
      computed: measuredLayout && measuredLayout.rootComputed
    }));
    project.elements = elements;
    project.selectedId = (nameNode && "qr-name") || (numberNode && "qr-number") || elements[0].id;
    project.css = "";
    project.html = "";
  }

  function findTextNodeContaining(root, text) {
    var nodes = Array.prototype.slice.call(root.querySelectorAll("*"));
    if (root.textContent && root.textContent.indexOf(text) >= 0) nodes.unshift(root);
    return nodes.find(function (node) {
      return node.children.length === 0 && String(node.textContent || "").indexOf(text) >= 0;
    }) || nodes.find(function (node) {
      return String(node.textContent || "").indexOf(text) >= 0;
    }) || null;
  }

  function findDecorationNodes(root, numberNode, nameNode) {
    var nodes = Array.prototype.slice.call(root.querySelectorAll("*"));
    return nodes.filter(function (node) {
      if (node === numberNode || node === nameNode) return false;
      if ((numberNode && node.contains(numberNode)) || (nameNode && node.contains(nameNode))) return false;
      var text = String(node.textContent || "").trim();
      var style = parseInlineStyle(node.getAttribute("style") || "");
      var className = String(node.getAttribute("class") || "").trim();
      var hasVisualBox = Boolean(
        style.height ||
        style.background ||
        style["background-color"] ||
        style["background-image"] ||
        style.border ||
        style["border-top"] ||
        style["border-bottom"] ||
        style["border-left"] ||
        style["border-right"]
      );
      if (!text && node.children.length === 0 && className) return true;
      if (!text) return hasVisualBox;
      if (text.indexOf("章节数") >= 0 || text.indexOf("章节名") >= 0) return false;
      return node.children.length === 0 && looksLikeDecorationText(text, style);
    });
  }

  function looksLikeDecorationText(text, style) {
    if (!text) return false;
    if (/^[\s◇◆○●·•\-—_=~*＊✦✧✽❖]+$/.test(text)) return true;
    return Boolean(style.color || style["font-size"] || style["letter-spacing"] || style["text-align"]);
  }

  function measureInlineTemplateLayout(root, targets, cssText) {
    if (!document.body) return null;
    var cleanup = [];
    Object.keys(targets || {}).forEach(function (key) {
      markMeasureTarget(targets[key], key, cleanup);
    });

    var host = document.createElement("div");
    var width = inlineTemplateMeasureWidth();
    host.style.cssText = [
      "position:absolute",
      "left:-10000px",
      "top:-10000px",
      "width:" + width + "px",
      "visibility:hidden",
      "pointer-events:none",
      "z-index:-1"
    ].join(";");
    if (cssText) {
      var style = document.createElement("style");
      style.textContent = cssText;
      host.appendChild(style);
    }
    var mount = document.createElement("div");
    mount.innerHTML = root.outerHTML;
    var rootClone = mount.firstElementChild;
    if (rootClone) host.appendChild(rootClone);
    document.body.appendChild(host);

    try {
      var measuredRoot = rootClone;
      if (!measuredRoot) return null;
      var rootRect = measuredRoot.getBoundingClientRect();
      var rootComputed = window.getComputedStyle ? window.getComputedStyle(measuredRoot) : null;
      var rootWidth = Math.max(1, rootRect.width || measuredRoot.scrollWidth || width);
      var rootHeight = Math.max(1, rootRect.height || measuredRoot.scrollHeight || 80);
      var layout = {
        canvasHeight: clampNumber(Math.ceil(rootHeight), 80, 360, 144),
        rootWidth: rootWidth,
        rootHeight: rootHeight,
        rootComputed: snapshotComputedStyle(rootComputed),
        nodes: {}
      };

      Object.keys(targets || {}).forEach(function (key) {
        var measuredNode = measuredRoot.querySelector('[data-qr-measure-id="' + cssEscape(key) + '"]');
        if (!measuredNode && measuredRoot.getAttribute("data-qr-measure-id") === key) {
          measuredNode = measuredRoot;
        }
        if (measuredNode) {
          layout.nodes[key] = layoutForInlineNode(measuredNode, rootRect, rootWidth, rootHeight);
        }
      });
      return layout;
    } finally {
      document.body.removeChild(host);
      cleanup.forEach(function (fn) { fn(); });
    }
  }

  function markMeasureTarget(node, key, cleanup) {
    if (!node) return;
    var hadAttribute = node.hasAttribute("data-qr-measure-id");
    var oldValue = node.getAttribute("data-qr-measure-id");
    node.setAttribute("data-qr-measure-id", key);
    cleanup.push(function () {
      if (hadAttribute) node.setAttribute("data-qr-measure-id", oldValue);
      else node.removeAttribute("data-qr-measure-id");
    });
  }

  function inlineTemplateMeasureWidth() {
    var rect = els.canvas && els.canvas.getBoundingClientRect ? els.canvas.getBoundingClientRect() : null;
    return Math.max(320, Math.round(rect && rect.width ? rect.width : 360));
  }

  function layoutForInlineNode(node, rootRect, rootWidth, rootHeight) {
    var rect = node.getBoundingClientRect();
    var computed = window.getComputedStyle ? window.getComputedStyle(node) : null;
    var left = rect.left - rootRect.left;
    var top = rect.top - rootRect.top;
    var width = rect.width || parseFloat(computed && computed.width) || rootWidth;
    var height = rect.height || parseFloat(computed && computed.height) || 1;
    left = clampNumber(left, 0, Math.max(0, rootWidth - 1), 0);
    top = clampNumber(top, 0, Math.max(0, rootHeight - 1), 0);
    width = clampNumber(width, 1, Math.max(1, rootWidth - left), rootWidth);
    height = clampNumber(height, 1, Math.max(1, rootHeight - top), 1);
    return {
      left: left,
      top: top,
      width: width,
      height: height,
      rootWidth: rootWidth,
      rootHeight: rootHeight,
      computed: snapshotComputedStyle(computed)
    };
  }

  function snapshotComputedStyle(computed) {
    if (!computed) return null;
    var keys = [
      "color",
      "font-family",
      "font-size",
      "font-weight",
      "line-height",
      "letter-spacing",
      "text-align",
      "text-shadow",
      "text-transform",
      "background-color",
      "background-image",
      "border-radius",
      "border-top",
      "border-bottom",
      "border-left",
      "border-right",
      "box-shadow",
      "padding"
    ];
    var snapshot = {};
    keys.forEach(function (key) {
      snapshot[key] = computed.getPropertyValue(key);
    });
    return {
      getPropertyValue: function (key) {
        return snapshot[key] || "";
      }
    };
  }

  function cssFromInlineNode(node, fallback, layout, type) {
    var inlineCSS = parseInlineStyle(node.getAttribute("style") || "");
    var css = Object.assign({}, fallback, inlineCSS);
    if (layout) {
      css.left = percentCSS(layout.left, layout.rootWidth);
      css.top = percentCSS(layout.top, layout.rootHeight);
      css.width = percentCSS(layout.width, layout.rootWidth);
      css.height = isInlineTextType(type) ? "auto" : round(layout.height, 2) + "px";
      css.margin = "0";
      applyComputedInlineStyle(css, inlineCSS, layout.computed, type);
    }
    css.left = css.left || fallback.left || "10%";
    css.top = css.top || fallback.top || "20%";
    css.width = css.width || fallback.width || "80%";
    css.height = css.height || fallback.height || "auto";
    css.position = "absolute";
    return css;
  }

  function applyComputedInlineStyle(css, inlineCSS, computed, type) {
    if (!computed) return;
    if (isInlineTextType(type)) {
      copyComputedIfInlineMissing(css, inlineCSS, computed, "color");
      copyComputedIfInlineMissing(css, inlineCSS, computed, "font-family");
      copyComputedIfInlineMissing(css, inlineCSS, computed, "font-size");
      copyComputedIfInlineMissing(css, inlineCSS, computed, "font-weight");
      copyComputedIfInlineMissing(css, inlineCSS, computed, "line-height");
      copyComputedIfInlineMissing(css, inlineCSS, computed, "letter-spacing");
      copyComputedIfInlineMissing(css, inlineCSS, computed, "text-align");
      copyComputedIfInlineMissing(css, inlineCSS, computed, "text-shadow");
      copyComputedIfInlineMissing(css, inlineCSS, computed, "text-transform");
    } else {
      copyComputedIfInlineMissing(css, inlineCSS, computed, "background-color");
      copyComputedIfInlineMissing(css, inlineCSS, computed, "background-image");
      copyComputedIfInlineMissing(css, inlineCSS, computed, "border-radius");
      copyComputedIfInlineMissing(css, inlineCSS, computed, "border-top");
      copyComputedIfInlineMissing(css, inlineCSS, computed, "border-bottom");
      copyComputedIfInlineMissing(css, inlineCSS, computed, "border-left");
      copyComputedIfInlineMissing(css, inlineCSS, computed, "border-right");
    }
  }

  function copyComputedIfInlineMissing(css, inlineCSS, computed, key) {
    var value = computed.getPropertyValue(key);
    if (key === "text-align") value = normalizeTextAlign(value);
    if (/^0px\s+none\b/.test(String(value || ""))) return;
    if (!inlineCSS[key] && value && value !== "none" && value !== "normal" && value !== "rgba(0, 0, 0, 0)") {
      css[key] = value;
    }
  }

  function normalizeTextAlign(value) {
    value = String(value || "").replace("-webkit-", "");
    if (value === "start") return "left";
    if (value === "end") return "right";
    return value;
  }

  function isInlineTextType(type) {
    return type === "chapterNumber" || type === "chapterName" || type === "text";
  }

  function percentCSS(value, total) {
    return round(value / Math.max(1, total) * 100, 3) + "%";
  }

  function canvasCSSFromInlineRoot(root, options) {
    var css = parseInlineStyle(root.getAttribute("style") || "");
    var canvasCSS = {};
    var keys = [
      "background",
      "background-color",
      "background-image",
      "background-size",
      "background-position",
      "border-radius",
      "border",
      "border-top",
      "border-bottom",
      "border-left",
      "border-right",
      "box-shadow"
    ];
    if (!options || !options.flattenLayout) {
      keys.push("padding");
    }
    keys.forEach(function (key) {
      if (css[key]) canvasCSS[key] = css[key];
      else if (options && options.computed && key !== "background" && key !== "border") {
        copyComputedIfInlineMissing(canvasCSS, css, options.computed, key);
      }
    });
    return canvasCSS;
  }

  function parseCSSRules(cssText) {
    var style = document.createElement("style");
    style.textContent = cssText;
    document.head.appendChild(style);
    var map = {};
    try {
      Array.prototype.slice.call(style.sheet.cssRules).forEach(function (rule) {
        if (!rule.selectorText || !rule.style) return;
        rule.selectorText.split(",").forEach(function (selector) {
          selector = selector.trim();
          map[selector] = map[selector] || {};
          for (var i = 0; i < rule.style.length; i += 1) {
            var name = rule.style[i];
            map[selector][name] = rule.style.getPropertyValue(name);
          }
        });
      });
    } catch (err) {
      document.head.removeChild(style);
      throw err;
    }
    document.head.removeChild(style);
    return map;
  }

  function parseInlineStyle(text) {
    var node = document.createElement("div");
    node.setAttribute("style", text);
    var css = {};
    for (var i = 0; i < node.style.length; i += 1) {
      var name = node.style[i];
      css[name] = node.style.getPropertyValue(name);
    }
    return css;
  }

  function cssBlockText(selector, css) {
    var lines = [selector + " {"];
    Object.keys(css || {}).forEach(function (key) {
      var value = css[key];
      if (value == null || value === "") return;
      lines.push("  " + key + ": " + value + ";");
    });
    lines.push("}");
    return lines.join("\n");
  }

  function cssDeclarationsFromBlock(text) {
    var source = String(text || "");
    var match = source.match(/\{([\s\S]*)\}/);
    var declarations = match ? match[1] : source;
    var parsed = parseInlineStyle(declarations);
    if (!Object.keys(parsed).length && declarations.trim()) {
      throw new Error("CSS 声明无法解析");
    }
    return parsed;
  }

  function applyTargetCSSText(element, text) {
    try {
      var parsed = cssDeclarationsFromBlock(text);
      mutate(function () {
        if (element) {
          element.css = Object.assign({}, parsed);
        } else {
          var height = parseFloat(parsed.height);
          if (Number.isFinite(height)) state.canvas.height = clampNumber(height, 80, 360, state.canvas.height);
          delete parsed.height;
          delete parsed.position;
          delete parsed.width;
          delete parsed.overflow;
          delete parsed["box-sizing"];
          state.canvas.css = sanitizedCanvasCSS(parsed);
        }
      }, element ? "修改元素 CSS" : "修改画布 CSS");
    } catch (err) {
      reportError("CSS 源码解析失败：" + err.message);
    }
  }

  function generateCSSText() {
    var parts = [];
    parts.push(".qr-title-canvas {");
    parts.push("  position: relative;");
    parts.push("  width: 100%;");
    parts.push("  height: " + state.canvas.height + "px;");
    parts.push("  overflow: hidden;");
    parts.push("  box-sizing: border-box;");
    var canvasCSS = sanitizedCanvasCSS(state.canvas.css || {});
    Object.keys(canvasCSS).forEach(function (key) {
      var value = canvasCSS[key];
      if (value) parts.push("  " + key + ": " + value + ";");
    });
    parts.push("}");
    state.elements.forEach(function (element) {
      parts.push("");
      parts.push(element.selector + " {");
      parts.push("  position: absolute;");
      parts.push("  box-sizing: border-box;");
      var css = Object.assign({}, element.css);
      if (!element.visible) css.display = "none";
      if (element.type === "backgroundImage" && element.assetId) {
        css["background-image"] = 'url("' + assetURL(element.assetId) + '")';
      }
      if (element.type === "image") {
        css.display = css.display || "block";
      }
      Object.keys(css).forEach(function (key) {
        var value = css[key];
        if (value == null || value === "") return;
        parts.push("  " + key + ": " + value + ";");
      });
      parts.push("}");
    });
    return parts.join("\n");
  }

  function generateHTMLText() {
    var html = ['<div class="qr-title-canvas">'];
    state.elements.forEach(function (element) {
      var className = selectorClassName(element.selector);
      var attrs = ' class="' + escapeAttr(className) + '" data-qr-id="' + escapeAttr(element.id) + '" data-qr-type="' + escapeAttr(element.type) + '"';
      if (element.locked) attrs += ' data-qr-locked="true"';
      if (element.type === "image") {
        html.push('  <img' + attrs + ' src="' + escapeAttr(assetURL(element.assetId)) + '" alt="' + escapeAttr(element.content || "图片") + '">');
      } else if (element.type === "chapterNumber") {
        html.push("  <p" + attrs + ">" + escapeHTML(element.content || "章节数") + "</p>");
      } else if (element.type === "chapterName") {
        html.push("  <h2" + attrs + ">" + escapeHTML(element.content || "章节名") + "</h2>");
      } else {
        html.push("  <div" + attrs + ">" + (isTextElement(element) ? escapeHTML(element.content) : "") + "</div>");
      }
    });
    html.push("</div>");
    return html.join("\n");
  }

  function htmlTemplateForExport() {
    if (sourceDirty) {
      return "<style>\n" + state.css + "\n</style>\n" + state.html;
    }
    return "<style>\n" + generateCSSText() + "\n</style>\n" + generateHTMLText();
  }

  function projectForSave(options) {
    return {
      schemaVersion: state.schemaVersion || 1,
      canvas: clone(state.canvas),
      elements: clone(state.elements),
      css: sourceDirty ? state.css : generateCSSText(),
      html: sourceDirty ? state.html : generateHTMLText(),
      assets: clone(state.assets),
      selectedId: options && options.includeSelection ? state.selectedId : undefined,
      sourceDirty: sourceDirty
    };
  }

  function exportPayload() {
    var htmlTemplate = htmlTemplateForExport();
    var assetIds = collectAssetIds(htmlTemplate);
    return {
      htmlTemplate: htmlTemplate,
      projectJSON: JSON.stringify(projectForSave({ includeSelection: false })),
      assetIds: assetIds,
      canvasHeight: state.canvas.height
    };
  }

  function draftPayload(label) {
    return {
      reason: label || "changed",
      htmlTemplate: htmlTemplateForExport(),
      projectJSON: JSON.stringify(projectForSave({ includeSelection: true })),
      assetIds: collectAssetIds(htmlTemplateForExport()),
      canvasHeight: state.canvas.height
    };
  }

  function exportProject() {
    commitFocusedControl();
    var validation = validateExport(false);
    if (!validation.valid) return null;
    var payload = exportPayload();
    postSwift("exportProject", payload);
    return payload;
  }

  function validateExport(showOK) {
    commitFocusedControl();
    var payload = exportPayload();
    var known = {};
    state.assets.forEach(function (asset) { known[asset.id] = true; });
    var missing = payload.assetIds.filter(function (id) { return !known[id]; });
    if (missing.length) {
      var message = "资源缺失，无法导出：" + missing.join(", ");
      reportError(message);
      return { valid: false, missingAssetIds: missing };
    }
    if (showOK) setStatus("导出检查通过");
    return { valid: true, missingAssetIds: [] };
  }

  function collectAssetIds(text) {
    var ids = {};
    var match;
    SOURCE_ASSET_RE.lastIndex = 0;
    while ((match = SOURCE_ASSET_RE.exec(text))) {
      ids[match[1]] = true;
    }
    state.elements.forEach(function (element) {
      if (element.assetId) ids[element.assetId] = true;
    });
    return Object.keys(ids);
  }

  function notifyChanged(label) {
    clearTimeout(notifyTimer);
    notifyTimer = setTimeout(function () {
      postSwift("projectChanged", draftPayload(label));
    }, 80);
  }

  function postSwift(name, payload) {
    var handlers = window.webkit && window.webkit.messageHandlers;
    if (!handlers) return;
    try {
      if (handlers[name]) handlers[name].postMessage(payload || {});
      if (handlers.chapterTitleDesigner) handlers.chapterTitleDesigner.postMessage({ type: name, payload: payload || {} });
      if (handlers.qireaderChapterTitleDesigner) handlers.qireaderChapterTitleDesigner.postMessage({ type: name, payload: payload || {} });
    } catch (err) {
      setStatus("Swift 通信失败：" + err.message);
    }
  }

  function reportError(message) {
    setStatus(message);
    postSwift("reportError", { message: message });
  }

  function setStatus(message) {
    if (els.status) els.status.textContent = message;
  }

  function assetURL(assetId) {
    if (!assetId) return "";
    var asset = state.assets.find(function (item) { return item.id === assetId; });
    return asset && asset.url ? asset.url : "qireader-title-asset://" + assetId;
  }

  function assetIdFromURL(url) {
    var match = String(url || "").match(/qireader-title-asset:\/\/([A-Za-z0-9._:-]+)/);
    return match ? match[1] : "";
  }

  function inferType(node, className) {
    if (className.indexOf("number") >= 0) return "chapterNumber";
    if (className.indexOf("name") >= 0) return "chapterName";
    if (className.indexOf("bg") >= 0) return "backgroundImage";
    if (node.tagName === "IMG") return "image";
    if (className.indexOf("box") >= 0) return "box";
    if (className.indexOf("decoration") >= 0) return "decoration";
    if (className.indexOf("line") >= 0) return "line";
    return "text";
  }

  function styleValue(rules, selector, property) {
    return rules[selector] && rules[selector][property] || "";
  }

  function numberCSS(element, key, fallback) {
    var value = parseFloat(element.css && element.css[key]);
    return Number.isFinite(value) ? value : fallback;
  }

  function parsePercent(value, fallback) {
    var number = parseFloat(String(value || "").replace("%", ""));
    return Number.isFinite(number) ? number : fallback;
  }

  function parseRotation(value) {
    var match = String(value || "").match(/rotate\(([-0-9.]+)deg\)/);
    return match ? Number(match[1]) : 0;
  }

  function colorValue(value, fallback) {
    if (/^#[0-9a-f]{3,8}$/i.test(String(value || ""))) return value;
    return fallback;
  }

  function isTransparentColor(value) {
    var normalized = String(value || "").replace(/\s+/g, "").toLowerCase();
    return !normalized || normalized === "transparent" || normalized === "rgba(0,0,0,0)";
  }

  function clampNumber(value, min, max, fallback) {
    var number = Number(value);
    if (!Number.isFinite(number)) number = fallback;
    return Math.min(max, Math.max(min, number));
  }

  function round(value, digits) {
    var scale = Math.pow(10, digits || 0);
    return Math.round(value * scale) / scale;
  }

  function clone(value) {
    return JSON.parse(JSON.stringify(value));
  }

  function selectorClassName(selector) {
    return String(selector || "").replace(/^\./, "").split(/[ .:#[]/)[0] || "qr-title-element";
  }

  function cssEscape(value) {
    if (window.CSS && window.CSS.escape) return window.CSS.escape(value);
    return String(value).replace(/"/g, '\\"');
  }

  function escapeHTML(value) {
    return String(value == null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;");
  }

  function escapeAttr(value) {
    return escapeHTML(value).replace(/"/g, "&quot;");
  }

  function uniqueId(prefix) {
    return "qr-" + prefix + "-" + shortId();
  }

  function shortId() {
    return Math.random().toString(36).slice(2, 8);
  }

  function apiInitProject(payload) {
      loadProject(normalizeProject(payload), { resetHistory: true });
      return true;
  }

  function apiSetAssets(assets) {
      assets = assets && Array.isArray(assets.assets) ? assets.assets : assets;
      state.assets = normalizeAssets(assets || []);
      renderAssetList();
      renderProperties();
      syncSourceFromProject();
      notifyChanged("设置资源");
      return true;
  }

  function apiInsertAsset(asset) {
      asset = asset && asset.asset ? asset.asset : asset;
      insertAsset(asset);
      return true;
  }

  function apiSetTheme(theme) {
      var name = typeof theme === "string" ? theme : theme && (theme.name || theme.mode || theme.scheme);
      document.documentElement.dataset.theme = name === "dark" ? "dark" : "";
      document.body.dataset.theme = name === "dark" ? "dark" : "";
      return true;
  }

  function apiSetFontEnvironment(payload) {
    var css = "";
    if (typeof payload === "string") css = payload;
    else if (payload && typeof payload.css === "string") css = payload.css;
    var styleNode = document.getElementById("qr-font-env");
    if (!styleNode) {
      styleNode = document.createElement("style");
      styleNode.id = "qr-font-env";
      document.head.appendChild(styleNode);
    }
    styleNode.textContent = css;
    // 触发画布元素重排，让新字体立刻生效
    if (typeof renderCanvasElements === "function") {
      try { renderCanvasElements(); updateMoveableTarget(); } catch (e) {}
    }
    return true;
  }

  function receiveMessage(message) {
    var command = message && (message.command || message.type);
    var payload = message && Object.prototype.hasOwnProperty.call(message, "payload") ? message.payload : message;
    if (command === "initProject") return apiInitProject(payload);
    if (command === "setAssets") return apiSetAssets(payload);
    if (command === "insertAsset") return apiInsertAsset(payload);
    if (command === "setTheme") return apiSetTheme(payload);
    if (command === "setFontEnvironment") return apiSetFontEnvironment(payload);
    if (command === "exportProject") return exportProject();
    if (command === "validateExport") return validateExport(payload && payload.showOK);
    reportError("未知设计器命令：" + (command || ""));
    return false;
  }

  var publicAPI = {
    initProject: apiInitProject,
    setAssets: apiSetAssets,
    insertAsset: apiInsertAsset,
    setTheme: apiSetTheme,
    setFontEnvironment: apiSetFontEnvironment,
    exportProject: exportProject,
    validateExport: validateExport,
    receive: receiveMessage,
    requestExport: exportProject
  };

  window.ChapterTitleDesigner = publicAPI;
  window.qireaderTitleDesigner = Object.assign({}, window.ChapterTitleDesigner, {
    receive: receiveMessage,
    requestExport: exportProject
  });
  window.receiveQireaderTitleDesignerMessage = receiveMessage;
  window.exportProject = exportProject;

  function bootDesigner() {
    setup();
    if (Array.isArray(window.__qireaderPendingMessages)) {
      window.__qireaderPendingMessages.splice(0).forEach(function (message) {
        receiveMessage(message);
      });
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", bootDesigner);
  } else {
    bootDesigner();
  }
})();
