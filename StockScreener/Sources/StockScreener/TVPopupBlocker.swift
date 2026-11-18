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
      var words = ['time to upgrade','explore our plans','explore plans','upgrade now','upgrade your plan','see plans','compare plans',
                   'start free trial','start your free trial','try it for free','try for free','get more with','unlock more','special offer',
                   'limited time','black friday','cyber monday','% off','more tools and data','go pro','get premium','get essential','get plus'];
      function hit(t){ for (var k = 0; k < words.length; k++) if (t.indexOf(words[k]) >= 0) return true; return false; }
      function smallBox(el){ var r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 && r.width < 820 && r.height < 560; }
      // the promo card = the largest ancestor that is still a small box and holds no chart (canvas)
      function card(el){
        var best = null, cur = el, n = 0;
        while (cur && cur !== document.body && n < 14) {
          if (!smallBox(cur) || cur.querySelector('canvas')) break;
          best = cur; cur = cur.parentElement; n++;
        }
        return best;
      }
      function closeOrHide(box){
        if (!box || box.__ssDone) return; box.__ssDone = true;
        var btns = box.querySelectorAll('button,[role="button"],[aria-label],[data-name]');
        for (var i = 0; i < btns.length; i++) {
          var b = btns[i], lab = ((b.getAttribute('aria-label')||'') + ' ' + (b.getAttribute('data-name')||'') + ' ' + (b.className||'')).toLowerCase();
          if (lab.indexOf('close') >= 0 || lab.indexOf('dismiss') >= 0 || (b.innerText||'').trim() === '×') { try { b.click(); } catch(e){} break; }
        }
        setTimeout(function(){ if (document.body.contains(box)) box.style.setProperty('display','none','important'); }, 120);
      }
      function scan(){
        var all = document.body ? document.body.querySelectorAll('div,section,aside,p,span,h1,h2,h3,h4,a,button') : [];
        for (var i = 0; i < all.length; i++) {
          var el = all[i];
          if (el.childElementCount > 6) continue;                 // leaf-ish text nodes only
          var t = (el.innerText || el.textContent || '').toLowerCase();
          if (t.length < 4 || t.length > 160 || !hit(t)) continue;
          var box = card(el);
          if (box) closeOrHide(box);
        }
      }
      var timer = null;
      new MutationObserver(function(){ if (timer) return; timer = setTimeout(function(){ timer = null; scan(); }, 250); })
        .observe(document.documentElement, {childList: true, subtree: true, characterData: true});
      setInterval(scan, 3000);
      scan();
    })();
    """#
}
