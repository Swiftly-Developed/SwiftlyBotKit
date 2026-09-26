import Foundation

/// Colour tokens and layout for the dashboard.
///
/// The five categorical slots are the validated default data-viz palette, in its
/// fixed order, mapped onto `AIAgentPurpose.displayOrder`. The order is the
/// colourblind-safety mechanism rather than a preference, so the stack is drawn
/// in the same order the slots are assigned: adjacent segments are then always
/// adjacent slots, which is the pairing the palette was validated against
/// (worst adjacent CVD ΔE 9.1 light / 8.4 dark).
///
/// Three of the light steps sit below 3:1 against the light surface, which the
/// palette's relief rule allows only with visible labels or a table view. Both
/// ship here: every legend entry carries its own count, and the agent and page
/// breakdowns are tables of numbers, so nothing is encoded by colour alone.
enum DashboardTheme {

    /// CSS variable holding this purpose's series colour.
    static func seriesVariable(for purpose: AIAgentPurpose) -> String {
        guard let index = AIAgentPurpose.displayOrder.firstIndex(of: purpose) else {
            return "--series-5"
        }
        return "--series-\(index + 1)"
    }

    static func seriesColor(for purpose: AIAgentPurpose) -> String {
        "var(\(seriesVariable(for: purpose)))"
    }

    static let css = """
    *{box-sizing:border-box}
    :root{
      color-scheme:light;
      --surface-1:#fcfcfb; --page:#f9f9f7;
      --text-primary:#0b0b0b; --text-secondary:#52514e; --muted:#898781;
      --grid:#e1e0d9; --baseline:#c3c2b7; --border:rgba(11,11,11,.10);
      --series-1:#2a78d6; --series-2:#eb6834; --series-3:#1baf7a; --series-4:#eda100; --series-5:#e87ba4;
      --series-1-soft:#86b6ef;
      --critical:#d03b3b; --good:#006300;
    }
    @media (prefers-color-scheme:dark){
      :root:not([data-theme="light"]){
        color-scheme:dark;
        --surface-1:#1a1a19; --page:#0d0d0d;
        --text-primary:#ffffff; --text-secondary:#c3c2b7; --muted:#898781;
        --grid:#2c2c2a; --baseline:#383835; --border:rgba(255,255,255,.10);
        --series-1:#3987e5; --series-2:#d95926; --series-3:#199e70; --series-4:#c98500; --series-5:#d55181;
        --series-1-soft:#184f95;
        --critical:#d03b3b; --good:#0ca30c;
      }
    }
    body{margin:0;background:var(--page);color:var(--text-primary);
      font:15px/1.5 system-ui,-apple-system,'Segoe UI',sans-serif}
    main{max-width:1120px;margin:0 auto;padding:28px 20px 64px}
    a{color:var(--series-1)}

    /* Header + filters */
    .top{display:flex;flex-wrap:wrap;gap:12px;align-items:flex-end;justify-content:space-between;margin-bottom:8px}
    h1{font-size:21px;margin:0}
    .sub{margin:2px 0 0;color:var(--text-secondary);font-size:13px}
    .filters{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin:18px 0 22px}
    .pills{display:flex;gap:4px;background:var(--surface-1);border:1px solid var(--border);border-radius:9px;padding:3px}
    .pill{padding:5px 11px;border-radius:6px;font-size:13px;font-weight:600;text-decoration:none;color:var(--text-secondary)}
    .pill.on{background:var(--text-primary);color:var(--surface-1)}
    .pill:focus-visible{outline:2px solid var(--series-1);outline-offset:2px}
    select,.btn{font:inherit;font-size:13px;font-weight:600;padding:7px 11px;border-radius:8px;
      border:1px solid var(--border);background:var(--surface-1);color:var(--text-primary);cursor:pointer}
    .spacer{flex:1}
    .switcher{position:relative}
    .switcher summary{list-style:none;display:flex;align-items:center;gap:8px;font-size:13px;font-weight:600;
      padding:5px 11px 5px 6px;border-radius:9px;border:1px solid var(--border);background:var(--surface-1);cursor:pointer}
    .switcher summary::-webkit-details-marker{display:none}
    .switcher summary:focus-visible,.switcher .menu a:focus-visible{outline:2px solid var(--series-1);outline-offset:2px}
    .switcher .chev{color:var(--muted);font-size:11px}
    .switcher .menu{position:absolute;z-index:10;top:calc(100% + 6px);left:0;min-width:250px;padding:4px;
      background:var(--surface-1);border:1px solid var(--border);border-radius:10px;box-shadow:0 8px 24px rgba(0,0,0,.18)}
    .switcher .menu a{display:flex;align-items:center;gap:10px;padding:7px 9px;border-radius:7px;
      font-size:13px;font-weight:600;color:var(--text-primary);text-decoration:none}
    .switcher .menu a:hover{background:var(--grid)}
    .switcher .menu a.on{background:var(--grid)}
    .logo{width:24px;height:24px;border-radius:6px;flex:none;display:block}
    .logo.all{display:grid;grid-template-columns:1fr 1fr;gap:2px}
    .logo.all img{width:11px;height:11px;border-radius:3px;display:block}

    /* Tiles */
    .tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(144px,100%),1fr));gap:12px;margin-bottom:24px}
    .tile{background:var(--surface-1);border:1px solid var(--border);border-radius:12px;padding:14px 16px}
    .tile .label{color:var(--text-secondary);font-size:12px;font-weight:600}
    .tile .value{font-size:28px;font-weight:650;margin-top:4px;letter-spacing:-.01em}
    .tile .note{color:var(--muted);font-size:12px;margin-top:2px}
    .tile.hero .value{font-size:44px}
    /* Phones: the headline number takes a row, the other four pair up. */
    @media (max-width:520px){.tile.hero{grid-column:1/-1}}
    .tile .value.alert{color:var(--critical)}

    /* Cards */
    .card{background:var(--surface-1);border:1px solid var(--border);border-radius:12px;padding:16px 18px;margin-bottom:20px}
    .card h2{font-size:15px;margin:0 0 2px}
    .card .hint{color:var(--text-secondary);font-size:12.5px;margin:0 0 14px}
    .cols{display:grid;grid-template-columns:1fr 1fr;gap:20px}
    @media (max-width:820px){.cols{grid-template-columns:1fr}}

    /* Legend: every entry carries its own count, which is the relief the
       light palette's sub-3:1 steps require. */
    .legend{display:flex;flex-wrap:wrap;gap:6px 18px;margin-top:14px}
    .legend div{display:flex;align-items:center;gap:7px;font-size:12.5px;color:var(--text-secondary)}
    .legend i{width:10px;height:10px;border-radius:3px;display:inline-block;flex:none}
    .legend b{color:var(--text-primary);font-weight:650;font-variant-numeric:tabular-nums}

    /* Horizontal bar rows */
    .rows{display:flex;flex-direction:column;gap:11px}
    .row .head{display:flex;justify-content:space-between;gap:12px;align-items:baseline;font-size:13px}
    .row .name{font-weight:600;overflow-wrap:anywhere}
    .row .meta{color:var(--muted);font-size:12px;font-weight:400}
    .row .num{color:var(--text-primary);font-weight:650;font-variant-numeric:tabular-nums;flex:none}
    .track{height:8px;background:var(--grid);border-radius:999px;margin-top:5px;overflow:hidden}
    .fill{height:100%;border-radius:0 4px 4px 0}
    .fill .seg{height:100%;border-right:2px solid var(--surface-1)}
    .fill .seg.whole{border-right:0;border-radius:0 4px 4px 0}

    .tag{display:inline-block;padding:0 6px;border-radius:999px;font-size:11px;font-weight:650;
      border:1px solid var(--border);color:var(--text-secondary);margin-left:6px}
    .tag.bad{color:var(--critical);border-color:var(--critical)}

    .empty{text-align:center;padding:36px 16px;color:var(--text-secondary);font-size:14px}
    svg{display:block;width:100%;height:auto}
    /* Below ~560px the chart would shrink its labels past legibility, so it
       keeps a minimum width and scrolls sideways inside its card instead. */
    .chart{overflow-x:auto;-webkit-overflow-scrolling:touch}
    .chart svg{min-width:560px}
    .axis{fill:var(--muted);font-size:11px}

    /* Export form. No script: the custom dates are dimmed, not hidden, when
       another period is picked, so a browser without :has() still shows them. */
    .export .fields{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(240px,100%),1fr));gap:16px}
    .export fieldset{border:1px solid var(--border);border-radius:10px;padding:10px 12px 12px;margin:0;min-width:0}
    .export legend{font-size:12px;font-weight:650;color:var(--text-secondary);padding:0 4px}
    .choice{display:flex;gap:9px;align-items:flex-start;padding:5px 2px;font-size:13.5px;cursor:pointer}
    .choice input{margin:3px 0 0;accent-color:var(--series-1);flex:none}
    .choice b{font-weight:600}
    .choice small{display:block;color:var(--muted);font-size:12px;line-height:1.35}
    .dates{display:flex;flex-wrap:wrap;gap:8px;margin:6px 0 4px 24px}
    .dates label{display:flex;flex-direction:column;gap:2px;font-size:12px;color:var(--text-secondary)}
    .dates input{font:inherit;font-size:13px;padding:5px 8px;border-radius:7px;border:1px solid var(--border);
      background:var(--page);color:var(--text-primary)}
    .export:has(#range-custom:not(:checked)) .dates{opacity:.45}
    .export fieldset .hint{margin:6px 0 0}
    .actions{margin-top:16px;display:flex;justify-content:flex-end}
    .btn.primary{background:var(--text-primary);color:var(--surface-1);border-color:var(--text-primary);padding:9px 16px}
    .btn:focus-visible,.choice input:focus-visible,.dates input:focus-visible{outline:2px solid var(--series-1);outline-offset:2px}
    .notice{border:1px solid var(--critical);color:var(--critical);background:var(--surface-1);border-radius:10px;
      padding:10px 14px;font-size:13.5px;font-weight:600;margin-bottom:16px}
    .columns{display:grid;grid-template-columns:max-content 1fr;gap:6px 16px;margin:0;font-size:13px}
    .columns dt{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;font-weight:600}
    .columns dd{margin:0;color:var(--text-secondary)}
    @media (max-width:560px){.columns{grid-template-columns:1fr}.columns dd{margin-bottom:6px}}
    """
}
