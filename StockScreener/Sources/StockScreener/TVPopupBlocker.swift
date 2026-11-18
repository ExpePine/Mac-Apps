import WebKit

/// Closes TradingView's upgrade / promo pop-ups ("Time to upgrade?", "Explore our plans" … marked AD) inside the
/// app's chart pages. Works like an ad blocker: it looks for those texts in small floating boxes and presses their ✕
/// (or hides the box). The chart itself is never touched. Off: UserDefaults "tv.blockPromos" = false.
enum TVPopupBlocker {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "tv.blockPromos") as? Bool ?? true }

    static func install(_ config: WKWebViewConfiguration) {
        guard enabled else { return }
        config.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    private static let js = #"""
    (function(){
      if (window.__ssPromo) return; window.__ssPromo = true;
      var words = ['time to upgrade','explore our plans','upgrade now','upgrade your plan','see plans','compare plans',
                   'start free trial','try it for free','get more with','unlock more','special offer','limited time','black friday','cyber monday'];
      function small(el){ var r = el.getBoundingClientRect(); return r.width > 0 && r.width < 760 && r.height > 0 && r.height < 520; }
      function floating(el){ var p = getComputedStyle(el).position; return p === 'fixed' || p === 'absolute' || p === 'sticky' || el.getAttribute('role') === 'dialog'; }
      function handle(box){
        if (!box || box.__ssDone) return; box.__ssDone = true;
        var close = box.querySelector('[aria-label*="lose" i],[data-name*="close" i],[class*="close" i] button,button[class*="close" i]');
        if (close) { try { close.click(); } catch(e){} }
        setTimeout(function(){ if (document.body.contains(box)) box.style.setProperty('display','none','important'); }, 150);
      }
      function scan(root){
        var all = (root || document.body).querySelectorAll('div,section,aside');
        for (var i = 0; i < all.length; i++) {
          var el = all[i];
          if (el.childElementCount > 40) continue;
          var t = (el.innerText || '').toLowerCase();
          if (t.length < 8 || t.length > 400) continue;
          var hit = false; for (var k = 0; k < words.length; k++) if (t.indexOf(words[k]) >= 0) { hit = true; break; }
          if (!hit) continue;
          // the smallest floating ancestor that is still a small box (the toast), never the page / chart
          var box = el, n = 0;
          while (box && box !== document.body && n < 10 && !floating(box)) { box = box.parentElement; n++; }
          if (box && box !== document.body && small(box) && !box.querySelector('canvas')) handle(box);
        }
      }
      var timer = null;
      new MutationObserver(function(){ if (timer) return; timer = setTimeout(function(){ timer = null; scan(); }, 400); })
        .observe(document.documentElement, {childList: true, subtree: true});
      scan();
    })();
    """#
}
