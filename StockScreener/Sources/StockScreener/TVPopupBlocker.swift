import WebKit

/// Closes TradingView's upgrade / promo pop-ups ("Time to upgrade?", "Explore our plans" … marked AD) inside the
/// app's chart pages. Three layers:
///  1. A WebKit content-blocker (like Safari ad blockers): blocks ad / promo network requests and hides elements whose
///     names look like promos, in every frame, before they can draw.
///  2. A script in every frame (also inside iframes and shadow DOM) that finds promo text in small boxes and presses
///     their ✕ or hides them; it remembers the box's class so the same pop-up is hidden instantly next time.
///  3. A counter (Chart viewer ⋯ menu) so you can see the blocker is working.
/// The chart itself (anything with a canvas) is never touched. Off: UserDefaults "tv.blockPromos" = false.
enum TVPopupBlocker {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "tv.blockPromos") as? Bool ?? true }
    static var closedCount: Int { UserDefaults.standard.integer(forKey: "tv.promosClosed") }
    static var lastClosed: String { UserDefaults.standard.string(forKey: "tv.promoLast") ?? "" }

    private static var ruleList: WKContentRuleList?
    private static var waiting: [WKUserContentController] = []
    private static let counter = Counter()

    static func install(_ config: WKWebViewConfiguration) {
        guard enabled else { return }
        let ucc = config.userContentController
        ucc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        ucc.removeScriptMessageHandler(forName: "ssPromo")
        ucc.add(counter, name: "ssPromo")
        if let r = ruleList { ucc.add(r) } else { waiting.append(ucc); compileRules() }
    }

    private static var compiling = false
    private static func compileRules() {
        guard !compiling else { return }
        compiling = true
        WKContentRuleListStore.default()?.compileContentRuleList(forIdentifier: "ss-tv-promos-v1", encodedContentRuleList: rules) { list, _ in
            DispatchQueue.main.async {
                compiling = false
                guard let list else { waiting = []; return }
                ruleList = list
                waiting.forEach { $0.add(list) }
                waiting = []
            }
        }
    }

    /// Content-blocker rules (WebKit / Safari format).
    private static let rules = #"""
    [
      {"trigger":{"url-filter":"doubleclick\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"googlesyndication\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"adservice\\.google"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"googletagservices\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"amazon-adsystem\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*","if-domain":["*tradingview.com"]},
       "action":{"type":"css-display-none","selector":"[data-dialog-name*='gopro' i], [data-dialog-name*='upgrade' i], [data-dialog-name*='promo' i], [data-name*='gopro' i], [data-name*='promo' i], [data-name*='upgrade-' i], [data-qa-id*='promo' i], [class*='promoToast' i], [class*='promo-toast' i], [class*='nagScreen' i], [class*='adBanner' i], [id*='google_ads' i]"}}
    ]
    """#

    private final class Counter: NSObject, WKScriptMessageHandler {
        func userContentController(_ ucc: WKUserContentController, didReceive m: WKScriptMessage) {
            let text = (m.body as? String) ?? ""
            Task { @MainActor in
                let d = UserDefaults.standard
                d.set(d.integer(forKey: "tv.promosClosed") + 1, forKey: "tv.promosClosed")
                d.set(String(text.prefix(80)), forKey: "tv.promoLast")
            }
        }
    }

    private static let js = #"""
    (function(){
      if (window.__ssPromo) return; window.__ssPromo = true;
      var words = ['time to upgrade','explore our plans','explore plans','upgrade now','upgrade your plan','see plans','compare plans',
                   'start free trial','start your free trial','try it for free','try for free','get more with','unlock more','special offer',
                   'limited time','black friday','cyber monday','% off','more tools and data','go pro','get premium','get essential','get plus',
                   'upgrade to','upgrade plan','choose a plan','view plans','your trial','trial ends','subscribe now','better market decisions'];
      function hit(t){ for (var k = 0; k < words.length; k++) if (t.indexOf(words[k]) >= 0) return true; return false; }
      function smallBox(el){ var r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 && r.width < 900 && r.height < 620; }
      function hasCanvas(el){ try { return !!el.querySelector('canvas'); } catch(e){ return false; } }
      // the promo card = the largest ancestor that is still a small box and holds no chart (canvas)
      function card(el){
        var best = null, cur = el, n = 0;
        while (cur && cur.nodeType === 1 && cur !== document.body && n < 16) {
          if (!smallBox(cur) || hasCanvas(cur)) break;
          best = cur;
          cur = cur.parentElement || (cur.getRootNode && cur.getRootNode().host) || null; n++;
        }
        return best;
      }
      // remember the card's class so the same pop-up is hidden at once next time
      var learned = []; try { learned = JSON.parse(localStorage.getItem('__ssPromoCls') || '[]'); } catch(e){}
      var styleEl = null;
      function applyLearned(){
        if (!learned.length) return;
        if (!styleEl) { styleEl = document.createElement('style'); (document.head || document.documentElement).appendChild(styleEl); }
        styleEl.textContent = learned.map(function(c){ return '.' + CSS.escape(c) + '{display:none !important}'; }).join('\n');
      }
      function learn(box){
        var cls = (box.className && typeof box.className === 'string') ? box.className.split(/\s+/).filter(function(c){ return c.length > 3 && !/^(open|show|visible|active)$/i.test(c); }) : [];
        if (!cls.length) return;
        var c = cls[0]; if (learned.indexOf(c) >= 0) return;
        learned.push(c); if (learned.length > 20) learned.shift();
        try { localStorage.setItem('__ssPromoCls', JSON.stringify(learned)); } catch(e){}
        applyLearned();
      }
      function closeOrHide(box, text){
        if (!box || box.__ssDone) return; box.__ssDone = true;
        var btns = box.querySelectorAll('button,[role="button"],[aria-label],[data-name],svg');
        for (var i = 0; i < btns.length; i++) {
          var b = btns[i], lab = ((b.getAttribute && (b.getAttribute('aria-label')||'') + ' ' + (b.getAttribute('data-name')||'') + ' ' + (b.getAttribute('title')||'')) + ' ' + (typeof b.className === 'string' ? b.className : '')).toLowerCase();
          if (lab.indexOf('close') >= 0 || lab.indexOf('dismiss') >= 0 || (b.innerText||'').trim() === '×' || (b.innerText||'').trim() === '✕') {
            try { (b.closest && b.closest('button,[role="button"]') || b).click(); } catch(e){} break;
          }
        }
        box.style.setProperty('display','none','important');
        learn(box);
        try { window.webkit.messageHandlers.ssPromo.postMessage(text.slice(0, 80)); } catch(e){}
      }
      function scanRoot(root){
        var all = root.querySelectorAll('*');
        for (var i = 0; i < all.length; i++) {
          var el = all[i];
          if (el.shadowRoot) scanRoot(el.shadowRoot);
          if (el.childElementCount > 8) continue;                  // text-level elements only
          var t = (el.textContent || '').toLowerCase();            // textContent: no layout work (innerText forces it)
          if (t.length < 4 || t.length > 200 || !hit(t)) continue;
          var box = card(el);
          if (box) closeOrHide(box, t);
        }
      }
      function scan(){ if (document.body && !document.hidden) scanRoot(document.body); }
      // Only what was just added is looked at, and only if its text has a promo word — the chart's own updates
      // (prices, legend, crosshair) change text, not elements, and are ignored. A full sweep runs every 8 s.
      function scanAdded(el){
        if (!el || el.nodeType !== 1 || el.__ssDone) return;
        var t = (el.textContent || '').toLowerCase();
        if (t.length < 4 || !hit(t)) return;
        if (el.childElementCount <= 8 && t.length <= 200) { var b = card(el); if (b) { closeOrHide(b, t); return; } }
        scanRoot(el);
      }
      applyLearned();
      var timer = null, pending = [];
      new MutationObserver(function(ms){
        for (var i = 0; i < ms.length; i++) { var a = ms[i].addedNodes; for (var j = 0; j < a.length; j++) if (a[j].nodeType === 1) pending.push(a[j]); }
        if (!pending.length || timer) return;
        timer = setTimeout(function(){ timer = null; var p = pending; pending = []; for (var k = 0; k < p.length; k++) scanAdded(p[k]); }, 400);
      }).observe(document.documentElement, {childList: true, subtree: true});
      setInterval(scan, 8000);
      scan();
    })();
    """#
}
