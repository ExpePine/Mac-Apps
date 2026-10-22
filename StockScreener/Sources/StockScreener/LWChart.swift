import SwiftUI
import WebKit

// MARK: - TradingView-style interactive chart (TradingView's open-source Lightweight Charts™ library)
//
// Wheel / pinch to zoom, drag to pan, crosshair with values, double-click the time axis to reset.
// Candles (Yahoo) + delivery bars + the rolling ta.highest line on an overlay scale + orange background
// bands and arrows on signal days. The library is loaded from the jsDelivr CDN (pinned versions).

/// The things that can be drawn on the delivery charts — each one can be switched on / off.
enum ChartLayer: String, CaseIterable, Identifiable {
    case candles, deliv, high, bands, markers, prank, sma22, sma66, per, t3, news, deals
    var id: String { rawValue }
    func label(_ metric: String, _ length: Int) -> String {
        switch self {
        case .candles: return "Price candles (Yahoo)"
        case .deliv: return "Delivery bars — \(metric)"
        case .high: return "ta.highest(\(metric), \(length)) line"
        case .bands: return "Orange bands on signal days"
        case .markers: return "▲DQ markers on signal days"
        case .prank: return "ta.percentrank(\(metric), \(length))"
        case .sma22: return "ta.sma(delivery, 22) line"
        case .sma66: return "ta.sma(delivery, 66) line"
        case .per: return "Delivery % (DELIV_PER)"
        case .t3: return "T3 line (green rising / red falling) — \(T3Def.current.pine)"
        case .news: return "News (3–4 word labels, blue ●)"
        case .deals: return "Bulk / block deals (B▲ buy · S▼ sell)"
        }
    }
    var color: Color? {
        switch self {
        case .high: return Color(red: 0.16, green: 0.38, blue: 1)
        case .prank: return Color(red: 0.67, green: 0.28, blue: 0.74)
        case .sma22: return Color(red: 0, green: 0.74, blue: 0.83)
        case .sma66: return Color(red: 0.91, green: 0.12, blue: 0.39)
        case .per: return Color(red: 0.55, green: 0.76, blue: 0.29)
        case .t3: return .green
        case .news: return .blue
        case .deals: return .purple
        case .bands, .markers: return .orange
        default: return nil
        }
    }
    static let defaults: Set<ChartLayer> = [.candles, .deliv, .high, .bands, .markers, .prank, .t3]
    /// Stored as "a,b,c" in UserDefaults; "" = the defaults, "none" = nothing.
    static func decode(_ s: String) -> Set<ChartLayer> {
        if s.isEmpty { return defaults }
        var out = Set(s.split(separator: ",").compactMap { ChartLayer(rawValue: String($0)) })
        // saved before T3 existed (no "v2" marker): show T3 too
        if !s.contains("v2") && s != "none" { out.insert(.t3) }
        return out
    }
    static func encode(_ set: Set<ChartLayer>) -> String {
        set.isEmpty ? "none" : (allCases.filter(set.contains).map(\.rawValue) + ["v2"]).joined(separator: ",")
    }
}

/// "Layers" button: a popover of checkboxes choosing what the chart draws (stays open while you tick).
struct ChartLayersButton: View {
    @Binding var raw: String
    var metric: String
    var length: Int
    var options: [ChartLayer] = ChartLayer.allCases
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Label("Layers", systemImage: "square.3.layers.3d") }
            .help("Choose what the chart shows")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Show on chart").font(.headline)
                    ForEach(options) { l in
                        Toggle(isOn: Binding(get: { ChartLayer.decode(raw).contains(l) },
                                             set: { on in var s = ChartLayer.decode(raw); if on { s.insert(l) } else { s.remove(l) }; raw = ChartLayer.encode(s) })) {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2).fill(l.color ?? .gray).frame(width: 12, height: 3)
                                    .opacity(l.color == nil ? 0.5 : 1)
                                Text(l.label(metric, length))
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    Divider()
                    HStack {
                        Button("All") { raw = ChartLayer.encode(Set(options)) }
                        Button("Default") { raw = "" }
                    }
                    .controlSize(.small)
                }
                .padding(12)
                .fixedSize()
            }
    }
}

struct LWChartData: Encodable {
    struct Candle: Encodable { let time: String; let open, high, low, close: Double }
    struct Point: Encodable { let time: String; let value: Double?; var color: String? = nil }   // value nil = empty day (gap)
    struct Marker: Encodable {
        let time: String
        var position = "belowBar"
        var color = "#FF9800"
        var shape = "arrowUp"
        let text: String
        var info: String? = nil           // shown on the chart while the crosshair is on this day
        var full: [String]? = nil         // shown under the chart (headlines + source / deal details)
        init(time: String, text: String, position: String = "belowBar", color: String = "#FF9800", shape: String = "arrowUp",
             info: String? = nil, full: [String]? = nil) {
            self.time = time; self.text = text; self.position = position; self.color = color; self.shape = shape
            self.info = info; self.full = full
        }
    }
    var candles: [Candle] = []
    var deliv: [Point] = []
    var high: [Point] = []
    var bands: [Point] = []
    var markers: [Marker] = []
    var prank: [Point] = []           // ta.percentrank(metric, length), 0–100
    var sma22: [Point] = []
    var sma66: [Point] = []
    var per: [Point] = []             // DELIV_PER, 0–100
    var t3: [Point] = []              // T3 with green / red per point
    var t3Own = false                 // T3's source differs from the bars → its own scale
    var t3Name = ""
    var title = ""
    var metric = ""
    var range = "1Y"          // 6M / 1Y / 2Y / All
    var dark = true

    /// Builds the chart data for one stock from its delivery series and (optional) Yahoo candles.
    static func make(symbol: String, series: DeliverySeries?, candles: [YahooClient.Candle], metric: DeliveryMetric,
                     length: Int, full: Bool, onlyRises: Bool, range: String, dark: Bool, calendar: [String] = [],
                     layers: Set<ChartLayer> = ChartLayer.defaults, events: [Marker] = []) -> LWChartData {
        var d = LWChartData()
        d.title = symbol
        d.metric = metric.pine
        d.range = range
        d.dark = dark
        var seen = Set<String>()
        d.candles = candles.compactMap { c in
            seen.insert(c.day).inserted ? Candle(time: c.day, open: c.open, high: c.high, low: c.low, close: c.close) : nil
        }
        if !layers.contains(.candles) { d.candles = [] }
        if let s = series {
            let m = s.metric(metric)
            if layers.contains(.prank) {
                for i in s.days.indices { if let pr = DeliveryColumns.percentRank(m, length: length, at: i) { d.prank.append(Point(time: s.days[i], value: pr)) } }
            }
            // SMA lines of the raw delivery (₹ value, or shares when the signal uses DELIV_QTY), on the bars' scale
            let base = metric == .qty ? s.qty : s.metric(value: true)
            for (n, l) in [(22, ChartLayer.sma22), (66, .sma66)] where layers.contains(l) {
                let sm = DeliverySignal.sma(base, n)
                let pts = s.days.indices.filter { $0 >= n - 1 }.map { Point(time: s.days[$0], value: sm[$0]) }
                if n == 22 { d.sma22 = pts } else { d.sma66 = pts }
            }
            if layers.contains(.t3) {
                let def = T3Def.current
                let t = def.t3(def.source(s))
                for i in s.days.indices { if let v = t[i] {
                    let up = i > 0 && t[i - 1] != nil && v > t[i - 1]!
                    d.t3.append(Point(time: s.days[i], value: v, color: up ? "#26a69a" : "#ef5350"))
                } }
                d.t3Own = def.useQty != (metric == .qty)
                d.t3Name = "T3(\(def.length))"
            }
            if layers.contains(.per) { d.per = s.days.indices.map { Point(time: s.days[$0], value: s.per[$0]) } }
            let h = DeliverySignal.highest(m, length: length, full: full)
            let sig = Set(DeliverySignal.signals(m, length: length, full: full, onlyRises: onlyRises))
            for i in s.days.indices {
                let isSig = sig.contains(i)
                d.deliv.append(Point(time: s.days[i], value: m[i], color: isSig ? "rgba(255,152,0,0.95)" : "rgba(128,128,128,0.45)"))
                if let v = h[i] { d.high.append(Point(time: s.days[i], value: v)) }
                if isSig {
                    if layers.contains(.bands) { d.bands.append(Point(time: s.days[i], value: 1, color: "rgba(255,152,0,0.22)")) }
                    if layers.contains(.markers) { d.markers.append(Marker(time: s.days[i], text: "DQ")) }
                }
            }
            if !layers.contains(.high) { d.high = [] }
            // Trading days with no NSE row for this stock: keep their place on the date axis (empty bar)
            if let first = s.days.first, let last = s.days.last {
                let have = Set(s.days)
                let empty = calendar.filter { $0 > first && $0 < last && !have.contains($0) }
                if !empty.isEmpty {
                    d.deliv = (d.deliv + empty.map { Point(time: $0, value: nil) }).sorted { $0.time < $1.time }
                }
            }
            if !layers.contains(.deliv) {
                // keep the dates on the axis, draw nothing
                d.deliv = d.deliv.map { Point(time: $0.time, value: nil) }
            }
        }
        d.markers += events
        return d
    }

    var json: String {
        var d = self
        d.markers.sort { $0.time < $1.time }          // the chart library wants markers in time order
        return (try? String(data: JSONEncoder().encode(d), encoding: .utf8)) ?? "{}"
    }

    /// News and bulk / block deal markers for one stock (shared by every delivery / news chart).
    @MainActor static func eventMarkers(_ symbol: String, layers: Set<ChartLayer>, from: String = "") -> [Marker] {
        var out: [Marker] = []
        let sym = symbol.uppercased()
        if layers.contains(.news) {
            let codes = EventCodes.all
            for nd in NewsTimeline.shared.days(sym) where nd.day >= from {
                guard let l = nd.label, l != "Not company news" else { continue }
                let code = EventCodes.code(for: nd.category, in: codes)
                out.append(Marker(time: nd.day, text: code, position: "aboveBar", color: "#2962FF", shape: "circle",
                                  info: "\(code) · \(l)" + (nd.category.map { " (\($0))" } ?? ""),
                                  full: nd.headlines.prefix(6).map { h in
                                      "\(nd.day) · \(h.title)" + (h.source.isEmpty ? "" : " — \(h.source)")
                                  }))
            }
        }
        if layers.contains(.deals) {
            DealsCenter.shared.loadIfNeeded()
            let byDay = Dictionary(grouping: DealsCenter.shared.bySymbol[sym] ?? [], by: \.day)
            for (day, ds) in byDay where day >= from {
                let buy = ds.filter(\.isBuy).reduce(0) { $0 + $1.valueCr }, sell = ds.filter { !$0.isBuy }.reduce(0) { $0 + $1.valueCr }
                let lines = ds.map { d in "\(d.day) · \(d.kind) \(d.isBuy ? "BUY" : "SELL") · \(d.client) · \(DeliveryView.short(d.qty)) shares @ \(String(format: "%.2f", d.price)) (\(String(format: "%.2f", d.valueCr)) Cr)" }
                if buy > 0 { out.append(Marker(time: day, text: "B", position: "belowBar", color: "#26a69a", shape: "arrowUp",
                                               info: String(format: "B · deal buys %.2f Cr", buy), full: lines.filter { $0.contains(" BUY ") })) }
                if sell > 0 { out.append(Marker(time: day, text: "S", position: "aboveBar", color: "#ef5350", shape: "arrowDown",
                                                info: String(format: "S · deal sells %.2f Cr", sell), full: lines.filter { $0.contains(" SELL ") })) }
            }
        }
        return out
    }
}

final class LWChartHolder: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    let view: WKWebView
    private var ready = false
    private var pending: String?
    @Published var failed = false
    @Published var lastError: String?
    /// Lines for the day under the crosshair (news headlines / deals) — shown under the chart.
    @Published var hoverLines: [String] = []
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
        ucc.add(WeakHandler(self), name: "hover")
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(Self.html, baseURL: URL(string: "https://cdn.jsdelivr.net/"))
    }

    func show(_ data: LWChartData) {
        let js = "window.setData(\(data.json))"
        if ready { view.evaluateJavaScript(js) { [weak self] r, e in self?.handle(r, e) } } else { pending = js }
    }

    private func handle(_ r: Any?, _ e: Error?) {
        let s = (r as? String) ?? e?.localizedDescription ?? ""
        failed = s == "nolib"
        lastError = s.hasPrefix("err:") || e != nil ? "Chart: \(s)" : nil
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        if m.name == "hover" { let l = (m.body as? [String]) ?? []; if l != hoverLines { hoverLines = l }; return }
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
        if let p = pending { pending = nil; webView.evaluateJavaScript(p) { [weak self] r, e in self?.handle(r, e) } }
    }

    static let html = """
    <!doctype html><html><head><meta charset="utf-8">
    <style>
      html,body{margin:0;height:100%;overflow:hidden;background:transparent;font:12px -apple-system,Helvetica,sans-serif}
      #c{position:absolute;inset:0}
      #legend{position:absolute;left:8px;top:6px;z-index:5;pointer-events:none;line-height:1.5}
      #legend b{font-size:13px}
      #tip{position:absolute;z-index:6;pointer-events:none;display:none;padding:3px 7px;border-radius:5px;font-size:12px;font-weight:600;
           background:rgba(41,98,255,0.92);color:#fff;white-space:nowrap;box-shadow:0 1px 4px rgba(0,0,0,0.3)}
      #err{position:absolute;inset:0;display:none;align-items:center;justify-content:center;color:#888}
    </style>
    <script src="https://cdn.jsdelivr.net/npm/lightweight-charts@4.2.0/dist/lightweight-charts.standalone.production.js"
            onerror="var s=document.createElement('script');s.src='https://unpkg.com/lightweight-charts@4.1.3/dist/lightweight-charts.standalone.production.js';document.head.appendChild(s);"></script>
    </head><body><div id="c"></div><div id="legend"></div><div id="tip"></div><div id="err">Chart library couldn't load (needs internet once).</div>
    <script>
    var chart=null, candle, hist, high, bands, prank, sma22, sma66, per, t3s, last=null, dark=null;
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
      prank=chart.addLineSeries({priceScaleId:'prank',color:'#AB47BC',lineWidth:1,lastValueVisible:true,priceLineVisible:false,crosshairMarkerVisible:false,
        title:'%rank',autoscaleInfoProvider:function(){ return {priceRange:{minValue:0,maxValue:100}}; }});
      per=chart.addLineSeries({priceScaleId:'per',color:'#8BC34A',lineWidth:1,lastValueVisible:false,priceLineVisible:false,crosshairMarkerVisible:false,
        autoscaleInfoProvider:function(){ return {priceRange:{minValue:0,maxValue:100}}; }});
      sma66=chart.addLineSeries({priceScaleId:'deliv',color:'#E91E63',lineWidth:1,lastValueVisible:false,priceLineVisible:false,crosshairMarkerVisible:false,priceFormat:{type:'custom',formatter:fmt}});
      sma22=chart.addLineSeries({priceScaleId:'deliv',color:'#00BCD4',lineWidth:1,lastValueVisible:false,priceLineVisible:false,crosshairMarkerVisible:false,priceFormat:{type:'custom',formatter:fmt}});
      t3s=chart.addLineSeries({priceScaleId:'deliv',color:'#26a69a',lineWidth:2,lastValueVisible:false,priceLineVisible:false,crosshairMarkerVisible:false,priceFormat:{type:'custom',formatter:fmt}});
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
        hover(p);
        if(!p || !p.time || !p.seriesData){ legendLast(); return; }
        var g=function(s){ return p.seriesData.get(s)||null; };
        legend(g(candle),g(hist),g(high),p.time,g(prank),g(sma22),g(sma66),g(per),g(t3s));
      });
      return true;
    }
    // Crosshair over a news / deal day: short text on the chart, full lines to the app (shown under the chart)
    var lastHover='';
    function hover(p){
      var tip=document.getElementById('tip');
      var key=(p&&p.time)?day(p.time):'';
      var h=key&&window._hover?window._hover[key]:null;
      if(!h || !p.point){ tip.style.display='none'; if(lastHover!==''){ lastHover=''; post([]); } return; }
      tip.innerHTML=h.map(function(x){ return '<div style="color:'+(x.color==='#2962FF'?'#fff':'#fff')+'">'+x.info+'</div>'; }).join('');
      tip.style.background=h[0].color==='#2962FF'?'rgba(41,98,255,0.92)':(h[0].color==='#26a69a'?'rgba(38,166,154,0.92)':'rgba(239,83,80,0.92)');
      tip.style.display='block';
      var w=document.body.clientWidth, x=p.point.x+14; if(x+tip.offsetWidth>w-70) x=p.point.x-14-tip.offsetWidth;
      tip.style.left=Math.max(4,x)+'px'; tip.style.top=Math.max(40,p.point.y-36)+'px';
      if(key!==lastHover){ lastHover=key; post([].concat.apply([],h.map(function(x){ return x.full||[]; }))); }
    }
    function post(lines){ if(window.webkit&&window.webkit.messageHandlers.hover) window.webkit.messageHandlers.hover.postMessage(lines); }
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
    function lastOf(a){ return a&&a.length?a[a.length-1]:null; }
    function legendLast(){ var d=last; legend(lastOf(d.candles),lastOf(d.deliv),lastOf(d.high),null,lastOf(d.prank),lastOf(d.sma22),lastOf(d.sma66),lastOf(d.per),lastOf(d.t3)); }
    function legend(c,h,x,t,pr,s22,s66,pc,t3v){
      var s='<b>'+last.title+'</b> ';
      if(t) s+=(typeof t==='string'?t:(t.year+'-'+String(t.month).padStart(2,'0')+'-'+String(t.day).padStart(2,'0')))+' ';
      if(c) s+='O '+c.open.toFixed(2)+' H '+c.high.toFixed(2)+' L '+c.low.toFixed(2)+' C <b>'+c.close.toFixed(2)+'</b>';
      s+='<br>';
      if(h&&h.value!=null) s+='<span style="color:#FF9800">'+last.metric+' '+fmt(h.value)+'</span>';
      if(x&&x.value!=null) s+=' &nbsp;<span style="color:#2962FF">highest '+fmt(x.value)+'</span>';
      if(s22&&s22.value!=null) s+=' &nbsp;<span style="color:#00BCD4">sma22 '+fmt(s22.value)+'</span>';
      if(s66&&s66.value!=null) s+=' &nbsp;<span style="color:#E91E63">sma66 '+fmt(s66.value)+'</span>';
      if(pr&&pr.value!=null) s+=' &nbsp;<span style="color:#AB47BC">percentrank '+pr.value.toFixed(1)+'</span>';
      if(pc&&pc.value!=null) s+=' &nbsp;<span style="color:#8BC34A">deliv '+pc.value.toFixed(0)+'%</span>';
      if(t3v&&t3v.value!=null){ var tc=t3v.color||'#26a69a'; s+=' &nbsp;<span style="color:'+tc+'">'+(last.t3Name||'T3')+' '+fmt(t3v.value)+(tc==='#26a69a'?' ▲':' ▼')+'</span>'; }
      document.getElementById('legend').innerHTML=s;
      document.getElementById('legend').style.color=dark?'#d1d4dc':'#131722';
    }
    window.setData=function(d){
      try { return window._setData(d); }
      catch(e) {
        try { d.deliv=d.deliv.filter(function(x){ return x.value!=null; }); window._setData(d); return 'ok-retry:'+e.message; }
        catch(e2) { return 'err:'+e2.message; }
      }
    };
    window._setData=function(d){
      if(!window.LightweightCharts){ document.getElementById('err').style.display='flex'; setTimeout(function(){ window.setData(d); },1500); return 'nolib'; }
      document.getElementById('err').style.display='none';
      if(!chart || dark!==d.dark) build(d.dark);
      last=d;
      var hasCandles=d.candles.length>0;
      chart.priceScale('deliv').applyOptions({scaleMargins:hasCandles?{top:0.72,bottom:0}:{top:0.08,bottom:0}});
      chart.priceScale('prank').applyOptions({scaleMargins:hasCandles?{top:0.72,bottom:0}:{top:0.08,bottom:0}, visible:false});
      chart.priceScale('per').applyOptions({scaleMargins:hasCandles?{top:0.72,bottom:0}:{top:0.08,bottom:0}, visible:false});
      chart.applyOptions({rightPriceScale:{visible:hasCandles}, leftPriceScale:{visible:false}});
      candle.setData(d.candles); hist.setData(d.deliv); high.setData(d.high); bands.setData(d.bands); prank.setData(d.prank||[]);
      sma22.setData(d.sma22||[]); sma66.setData(d.sma66||[]); per.setData(d.per||[]);
      t3s.applyOptions({priceScaleId:d.t3Own?'t3':'deliv'});
      if(d.t3Own) chart.priceScale('t3').applyOptions({scaleMargins:hasCandles?{top:0.72,bottom:0}:{top:0.08,bottom:0}, visible:false});
      t3s.setData(d.t3||[]);
      var ts={}; d.candles.forEach(function(x){ ts[x.time]=1; }); d.deliv.forEach(function(x){ ts[x.time]=1; });
      window._times=Object.keys(ts).sort();
      var hasBars=d.deliv.some(function(x){ return x.value!=null; });
      var mk=hasCandles?candle:(hasBars?hist:(d.high.length?high:hist));
      [candle,hist,high].forEach(function(s){ if(s!==mk) s.setMarkers([]); });
      // markers must sit on a bar of their series: move weekend / holiday news to the next trading day
      var st=(mk===candle?d.candles:(mk===hist?d.deliv:d.high)).filter(function(x){ return x.close!=null || x.value!=null; }).map(function(x){ return x.time; });
      var snapped=d.markers.map(function(m){
        if(!st.length) return m;
        var lo=0,hi=st.length-1; if(m.time>st[hi]) return null;
        while(lo<hi){ var md=(lo+hi)>>1; if(st[md]<m.time) lo=md+1; else hi=md; }
        var c=Object.assign({},m); c.time=st[lo]; return c;
      }).filter(function(m){ return m; });
      snapped.sort(function(a,b){ return a.time<b.time?-1:(a.time>b.time?1:0); });
      window._hover={};
      snapped.forEach(function(m){ if(m.info){ (window._hover[m.time]=window._hover[m.time]||[]).push({info:m.info,full:m.full,color:m.color}); } });
      mk.setMarkers(snapped.map(function(m){ return {time:m.time,position:m.position,color:m.color,shape:m.shape,text:m.text}; }));
      var n={'6M':126,'1Y':252,'2Y':504}[d.range];
      var len=Math.max(d.candles.length,d.deliv.length);
      window._quiet=true;
      if(n && len>n) chart.timeScale().setVisibleLogicalRange({from:len-n,to:len+4}); else chart.timeScale().fitContent();
      clearTimeout(window._qt); window._qt=setTimeout(function(){ window._quiet=false; },350);
      legendLast();
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
