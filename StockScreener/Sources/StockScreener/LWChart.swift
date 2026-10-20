import SwiftUI
import WebKit

// MARK: - TradingView-style interactive chart (TradingView's open-source Lightweight Charts™ library)
//
// Wheel / pinch to zoom, drag to pan, crosshair with values, double-click the time axis to reset.
// Candles (Yahoo) + delivery bars + the rolling ta.highest line on an overlay scale + orange background
// bands and arrows on signal days. The library is loaded from the jsDelivr CDN (pinned versions).

struct LWChartData: Encodable {
    struct Candle: Encodable { let time: String; let open, high, low, close: Double }
    struct Point: Encodable { let time: String; let value: Double; var color: String? = nil }
    struct Marker: Encodable { let time: String; let position = "belowBar"; let color = "#FF9800"; let shape = "arrowUp"; let text: String }
    var candles: [Candle] = []
    var deliv: [Point] = []
    var high: [Point] = []
    var bands: [Point] = []
    var markers: [Marker] = []
    var title = ""
    var metric = ""
    var range = "1Y"          // 6M / 1Y / 2Y / All
    var dark = true

    /// Builds the chart data for one stock from its delivery series and (optional) Yahoo candles.
    static func make(symbol: String, series: DeliverySeries?, candles: [YahooClient.Candle], useValue: Bool,
                     length: Int, full: Bool, onlyRises: Bool, range: String, dark: Bool) -> LWChartData {
        var d = LWChartData()
        d.title = symbol
        d.metric = useValue ? "DELIV_QTY×CLOSE" : "DELIV_QTY"
        d.range = range
        d.dark = dark
        var seen = Set<String>()
        d.candles = candles.compactMap { c in
            seen.insert(c.day).inserted ? Candle(time: c.day, open: c.open, high: c.high, low: c.low, close: c.close) : nil
        }
        if let s = series {
            let m = s.metric(value: useValue)
            let h = DeliverySignal.highest(m, length: length, full: full)
            let sig = Set(DeliverySignal.signals(m, length: length, full: full, onlyRises: onlyRises))
            for i in s.days.indices {
                let isSig = sig.contains(i)
                d.deliv.append(Point(time: s.days[i], value: m[i], color: isSig ? "rgba(255,152,0,0.95)" : "rgba(128,128,128,0.45)"))
                if let v = h[i] { d.high.append(Point(time: s.days[i], value: v)) }
                if isSig {
                    d.bands.append(Point(time: s.days[i], value: 1, color: "rgba(255,152,0,0.22)"))
                    d.markers.append(Marker(time: s.days[i], text: "DQ"))
                }
            }
        }
        return d
    }

    var json: String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}" }
}

final class LWChartHolder: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    let view: WKWebView
    private var ready = false
    private var pending: String?
    @Published var failed = false
    /// Called when YOU pan / zoom this chart: first and last visible day ("yyyy-MM-dd").
    var onUserRange: ((String, String) -> Void)?

    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ t: WKScriptMessageHandler) { target = t }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
    }

    override init() {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        cfg.userContentController = ucc
        view = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        ucc.add(WeakHandler(self), name: "range")
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(Self.html, baseURL: URL(string: "https://cdn.jsdelivr.net/"))
    }

    func show(_ data: LWChartData) {
        let js = "window.setData(\(data.json))"
        if ready { view.evaluateJavaScript(js) { [weak self] r, _ in if (r as? String) == "nolib" { self?.failed = true } } } else { pending = js }
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let a = m.body as? [String], a.count == 2 else { return }
        onUserRange?(a[0], a[1])
    }

    /// Shows the days `from`…`to` (moved by the other chart; doesn't echo back).
    func setRange(from: String, to: String) {
        guard ready else { return }
        view.evaluateJavaScript("window.setRange && window.setRange('\(from)','\(to)')", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        if let p = pending { pending = nil; webView.evaluateJavaScript(p) { [weak self] r, _ in if (r as? String) == "nolib" { self?.failed = true } } }
    }

    static let html = """
    <!doctype html><html><head><meta charset="utf-8">
    <style>
      html,body{margin:0;height:100%;overflow:hidden;background:transparent;font:12px -apple-system,Helvetica,sans-serif}
      #c{position:absolute;inset:0}
      #legend{position:absolute;left:8px;top:6px;z-index:5;pointer-events:none;line-height:1.5}
      #legend b{font-size:13px}
      #err{position:absolute;inset:0;display:none;align-items:center;justify-content:center;color:#888}
    </style>
    <script src="https://cdn.jsdelivr.net/npm/lightweight-charts@4.2.0/dist/lightweight-charts.standalone.production.js"
            onerror="var s=document.createElement('script');s.src='https://unpkg.com/lightweight-charts@4.1.3/dist/lightweight-charts.standalone.production.js';document.head.appendChild(s);"></script>
    </head><body><div id="c"></div><div id="legend"></div><div id="err">Chart library couldn't load (needs internet once).</div>
    <script>
    var chart=null, candle, hist, high, bands, last=null, dark=null;
    function fmt(v){ if(v==null) return ''; var a=Math.abs(v);
      if(a>=1e7) return (v/1e7).toFixed(2)+' Cr'; if(a>=1e5) return (v/1e5).toFixed(2)+' L';
      if(a>=1e3) return (v/1e3).toFixed(1)+' K'; return v.toFixed(2); }
    function build(isDark){
      var L=window.LightweightCharts; if(!L) return false;
      if(chart){ chart.remove(); chart=null; }
      dark=isDark;
      var fg=isDark?'#d1d4dc':'#131722', grid=isDark?'rgba(255,255,255,0.06)':'rgba(0,0,0,0.06)';
      chart=L.createChart(document.getElementById('c'),{autoSize:true,
        layout:{background:{type:'solid',color:'rgba(0,0,0,0)'},textColor:fg},
        grid:{vertLines:{color:grid},horzLines:{color:grid}},
        rightPriceScale:{scaleMargins:{top:0.06,bottom:0.32}},
        timeScale:{rightOffset:6,borderVisible:false},
        crosshair:{mode:0}});
      bands=chart.addHistogramSeries({priceScaleId:'bands',lastValueVisible:false,priceLineVisible:false,priceFormat:{type:'price'}});
      chart.priceScale('bands').applyOptions({scaleMargins:{top:0,bottom:0},visible:false});
      candle=chart.addCandlestickSeries({upColor:'#26a69a',downColor:'#ef5350',borderVisible:false,wickUpColor:'#26a69a',wickDownColor:'#ef5350'});
      hist=chart.addHistogramSeries({priceScaleId:'deliv',lastValueVisible:false,priceLineVisible:false,priceFormat:{type:'custom',formatter:fmt}});
      high=chart.addLineSeries({priceScaleId:'deliv',color:'#2962FF',lineWidth:2,lineType:1,lastValueVisible:false,priceLineVisible:false,crosshairMarkerVisible:false,priceFormat:{type:'custom',formatter:fmt}});
      chart.timeScale().subscribeVisibleTimeRangeChange(function(r){
        if(!r || window._quiet) return;
        clearTimeout(window._rt);
        window._rt=setTimeout(function(){
          if(window.webkit && window.webkit.messageHandlers.range) window.webkit.messageHandlers.range.postMessage([day(r.from), day(r.to)]);
        },120);
      });
      chart.subscribeCrosshairMove(function(p){
        if(!last) return;
        var c=p&&p.seriesData?p.seriesData.get(candle):null, h=p&&p.seriesData?p.seriesData.get(hist):null, x=p&&p.seriesData?p.seriesData.get(high):null;
        legend(c,h,x,p&&p.time);
      });
      return true;
    }
    function day(t){ if(typeof t==='string') return t; if(typeof t==='number'){ var d=new Date(t*1000); return d.toISOString().slice(0,10); }
      return t.year+'-'+String(t.month).padStart(2,'0')+'-'+String(t.day).padStart(2,'0'); }
    // Shows days f…t even when they run past the data (TradingView often shows empty days on the right):
    // converts dates to bar positions (extrapolating weekdays beyond the first / last bar).
    function wd(a,b){ var d1=new Date(a+'T00:00:00Z'), d2=new Date(b+'T00:00:00Z'), n=0, s=d1<d2?1:-1;
      for(var d=new Date(d1); s>0 ? d<d2 : d>d2; d.setUTCDate(d.getUTCDate()+s)){ var w=d.getUTCDay(); if(w!==0&&w!==6) n+=s; } return n; }
    function pos(day){
      var t=window._times||[]; if(!t.length) return 0;
      if(day<=t[0]) return -wd(day,t[0]);
      if(day>=t[t.length-1]) return (t.length-1)+wd(t[t.length-1],day);
      var lo=0,hi=t.length-1; while(lo<hi){ var m=(lo+hi)>>1; if(t[m]<day) lo=m+1; else hi=m; } return lo;
    }
    window.setRange=function(f,t){ if(!chart) return; window._quiet=true;
      try{ chart.timeScale().setVisibleLogicalRange({from:pos(f),to:pos(t)}); }catch(e){}
      clearTimeout(window._qt); window._qt=setTimeout(function(){ window._quiet=false; },350); };
    function legend(c,h,x,t){
      var s='<b>'+last.title+'</b> ';
      if(t) s+=(typeof t==='string'?t:(t.year+'-'+String(t.month).padStart(2,'0')+'-'+String(t.day).padStart(2,'0')))+' ';
      if(c) s+='O '+c.open.toFixed(2)+' H '+c.high.toFixed(2)+' L '+c.low.toFixed(2)+' C <b>'+c.close.toFixed(2)+'</b>';
      s+='<br><span style="color:#FF9800">'+last.metric+' '+(h?fmt(h.value):'')+'</span>';
      if(x) s+=' &nbsp;<span style="color:#2962FF">highest '+fmt(x.value)+'</span>';
      document.getElementById('legend').innerHTML=s;
      document.getElementById('legend').style.color=dark?'#d1d4dc':'#131722';
    }
    window.setData=function(d){
      if(!window.LightweightCharts){ document.getElementById('err').style.display='flex'; setTimeout(function(){ window.setData(d); },1500); return 'nolib'; }
      document.getElementById('err').style.display='none';
      if(!chart || dark!==d.dark) build(d.dark);
      last=d;
      var hasCandles=d.candles.length>0;
      chart.priceScale('deliv').applyOptions({scaleMargins:hasCandles?{top:0.72,bottom:0}:{top:0.08,bottom:0}});
      chart.applyOptions({rightPriceScale:{visible:hasCandles}, leftPriceScale:{visible:false}});
      candle.setData(d.candles); hist.setData(d.deliv); high.setData(d.high); bands.setData(d.bands);
      var ts={}; d.candles.forEach(function(x){ ts[x.time]=1; }); d.deliv.forEach(function(x){ ts[x.time]=1; });
      window._times=Object.keys(ts).sort();
      (hasCandles?candle:hist).setMarkers(d.markers);
      if(hasCandles) hist.setMarkers([]); else candle.setMarkers([]);
      var n={'6M':126,'1Y':252,'2Y':504}[d.range];
      var len=Math.max(d.candles.length,d.deliv.length);
      window._quiet=true;
      if(n && len>n) chart.timeScale().setVisibleLogicalRange({from:len-n,to:len+4}); else chart.timeScale().fitContent();
      clearTimeout(window._qt); window._qt=setTimeout(function(){ window._quiet=false; },350);
      legend(d.candles[d.candles.length-1],d.deliv[d.deliv.length-1],d.high[d.high.length-1],null);
      return 'ok';
    };
    </script></body></html>
    """
}

struct LWChartView: NSViewRepresentable {
    @ObservedObject var holder: LWChartHolder
    func makeNSView(context: Context) -> NSView { let v = NSView(); embed(v); return v }
    func updateNSView(_ v: NSView, context: Context) { if holder.view.superview !== v { embed(v) } }
    private func embed(_ v: NSView) {
        let w = holder.view
        w.removeFromSuperview()
        w.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(w)
        NSLayoutConstraint.activate([w.leadingAnchor.constraint(equalTo: v.leadingAnchor), w.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                                     w.topAnchor.constraint(equalTo: v.topAnchor), w.bottomAnchor.constraint(equalTo: v.bottomAnchor)])
    }
}

// MARK: - Pine Script that draws the same delivery signals on your TradingView charts

enum DeliveryPine {
    /// Builds a Pine v5 indicator holding "SYMBOL@yyyy-MM-dd;" keys for every signal day, split into
    /// short strings; on each bar it checks the chart's own symbol + date and paints the bar.
    static func script(signals: [(symbol: String, days: [String])], metric: String, length: Int) -> String {
        var keys = ""
        for s in signals.sorted(by: { $0.symbol < $1.symbol }) { for d in s.days { keys += "\(s.symbol)@\(d);" } }
        var chunks: [String] = []
        var cur = ""
        for k in keys.split(separator: ";") {
            if cur.count + k.count + 1 > 3000 { chunks.append(cur); cur = "" }
            cur += k + ";"
        }
        if !cur.isEmpty { chunks.append(cur) }
        let stamp = HistoryStore.dayKey(Date())
        var out = """
        //@version=5
        // Generated by Stock Screener on \(stamp): days where ta.highest(\(metric), \(length)) updated (NSE delivery data).
        // Re-copy from the app after new days to include new signals.
        indicator("Delivery highs (\(metric), \(length))", overlay = true, max_labels_count = 500)
        key = syminfo.ticker + "@" + str.format_time(time, "yyyy-MM-dd", "Asia/Kolkata") + ";"
        hit = false

        """
        for (i, c) in chunks.enumerated() {
            out += "s\(i) = \"\(c)\"\nhit := hit or str.contains(s\(i), key)\n"
        }
        out += """

        bgcolor(hit ? color.new(color.orange, 78) : na, title = "Delivery high day")
        plotshape(hit, title = "Delivery high", style = shape.triangleup, location = location.belowbar, color = color.orange, size = size.small, text = "DQ", textcolor = color.orange)

        """
        return out
    }
}


// MARK: - Keeping the TradingView page and the delivery chart on the same dates

/// Reads / sets the visible date range of the TradingView chart page through the chart API that tradingview.com
/// exposes in the page (window.TradingViewApi). Not an official, documented interface — it may be missing.
enum TVRange {
    /// Finds the chart controller in the TradingView page (several known places) — body for callAsyncJavaScript.
    static let finder = """
    function __ssChart() {
      var a = window.TradingViewApi || window.tradingViewApi;
      var tries = [];
      if (a) {
        tries.push(function(){ return a.activeChart && a.activeChart(); });
        tries.push(function(){ return a.chart && a.chart(0); });
        tries.push(function(){ return a._activeChartWidgetWV && a._activeChartWidgetWV.value(); });
      }
      for (var i = 0; i < tries.length; i++) {
        try { var c = tries[i](); if (c && typeof c.getVisibleRange === 'function') return c; } catch (e) {}
      }
      return null;
    }
    """

    /// Returns "from,to" (unix seconds) or a short reason it couldn't.
    static let getBody = finder + """
    var c = __ssChart();
    if (!c) {
      var keys = Object.keys(window).filter(function(k){ return /tradingview|tvapi|chartapi/i.test(k); }).slice(0, 8).join('|');
      return 'noapi:' + (typeof window.TradingViewApi) + (keys ? ':' + keys : '');
    }
    var r = c.getVisibleRange();
    if (r && typeof r.then === 'function') r = await r;
    if (!r || r.from == null) return 'norange';
    return Math.round(r.from) + ',' + Math.round(r.to);
    """

    static func setBody(from: Int, to: Int) -> String {
        finder + """
        var c = __ssChart();
        if (!c || typeof c.setVisibleRange !== 'function') return 'noapi';
        var p = c.setVisibleRange({from: \(from), to: \(to)});
        if (p && typeof p.then === 'function') await p;
        return 'ok';
        """
    }

    /// Runs one of the bodies above in the page and hands back its text result (or the error).
    static func run(_ web: WKWebView, _ body: String, done: @escaping (String) -> Void) {
        web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { r in
            switch r {
            case .success(let v): done((v as? String) ?? "\(v)")
            case .failure(let e): done("jserror: " + e.localizedDescription)
            }
        }
    }

    private static let f: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Kolkata"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static func day(_ unix: Int) -> String { f.string(from: Date(timeIntervalSince1970: TimeInterval(unix))) }
    static func unix(_ day: String) -> Int? { f.date(from: day).map { Int($0.timeIntervalSince1970) } }
}
