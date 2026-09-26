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

    /// How many colours the "Color by" chart has for individual values.
    /// Beyond them, values are folded into "Other".
    static let categoryCount = 24

    /// The colour for the value ranked `rank` (0 = largest) in a "Color by"
    /// breakdown.
    ///
    /// Twelve hues in an order that keeps neighbours far apart, then the
    /// same twelve again as a lighter (light theme) or deeper (dark theme)
    /// step, so a value's colour is never mistaken for the one stacked next
    /// to it. With up to 24 values colour alone cannot carry identity, which
    /// is why every legend entry and popover line names its value and count.
    static func categoryColor(rank: Int) -> String {
        "var(--cat-\((rank % categoryCount) + 1))"
    }

    /// Everything folded together beyond the top values.
    static let otherColor = "var(--cat-other)"
    /// Views that have no value for the chosen breakdown.
    static let unrecordedColor = "var(--cat-unrecorded)"

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
      --cat-1:#2a78d6; --cat-2:#eb6834; --cat-3:#1baf7a; --cat-4:#e87ba4; --cat-5:#eda100; --cat-6:#8b5cf6;
      --cat-7:#0e9fb5; --cat-8:#d03b3b; --cat-9:#7cb82f; --cat-10:#a86b3c; --cat-11:#5b6ee1; --cat-12:#c052c9;
      --cat-13:#86b6ef; --cat-14:#f6a57f; --cat-15:#74d3ae; --cat-16:#f3b3cc; --cat-17:#f5cb5c; --cat-18:#bda4fa;
      --cat-19:#6dcfdd; --cat-20:#ec8b8b; --cat-21:#b5dd7a; --cat-22:#d2a47f; --cat-23:#a3aef0; --cat-24:#e29be7;
      --cat-other:#898781; --cat-unrecorded:#d6d5ce;
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
        --cat-1:#3987e5; --cat-2:#d95926; --cat-3:#199e70; --cat-4:#d55181; --cat-5:#c98500; --cat-6:#9f7aea;
        --cat-7:#1bb3c9; --cat-8:#e05252; --cat-9:#8bc34a; --cat-10:#b97a4b; --cat-11:#6f7fe8; --cat-12:#cd67d6;
        --cat-13:#184f95; --cat-14:#8f3a17; --cat-15:#0f6b4b; --cat-16:#8e3457; --cat-17:#8a5c00; --cat-18:#5b3fa8;
        --cat-19:#0e6f7e; --cat-20:#962f2f; --cat-21:#52802c; --cat-22:#7a4f2f; --cat-23:#3a47a3; --cat-24:#85368c;
        --cat-other:#6f6e69; --cat-unrecorded:#3a3a37;
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

    /* Chart card header with the "Color by" menu on the right */
    .card-head{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:4px}
    .card-head h2{min-width:0}
    .colorby{position:relative;flex:none}
    .colorby summary{list-style:none;display:flex;align-items:center;gap:6px;padding:5px 10px;border-radius:8px;
      border:1px solid var(--border);background:var(--surface-1);cursor:pointer;font-size:12.5px;font-weight:600;
      color:var(--text-secondary);white-space:nowrap}
    .colorby summary::-webkit-details-marker{display:none}
    .colorby summary b{color:var(--text-primary);font-weight:650}
    .colorby summary:focus-visible,.colorby .menu a:focus-visible{outline:2px solid var(--series-1);outline-offset:2px}
    .colorby .menu{position:absolute;right:0;top:calc(100% + 6px);z-index:30;min-width:200px;max-height:360px;overflow-y:auto;
      padding:5px;background:var(--surface-1);border:1px solid var(--border);border-radius:10px;box-shadow:0 8px 24px rgba(0,0,0,.18)}
    .colorby .menu a{display:block;padding:6px 10px;border-radius:6px;font-size:13px;font-weight:600;color:var(--text-primary);text-decoration:none}
    .colorby .menu a:hover,.colorby .menu a.on{background:var(--grid)}
    .colorby .menu .group{padding:8px 10px 3px;font-size:11px;font-weight:650;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
    .legend.totals{gap:8px 20px}
    .legend.totals em{font-style:normal;color:var(--muted);font-variant-numeric:tabular-nums}

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
    .fill.split{display:flex;overflow:hidden}
    .fill.split .seg{flex:none}
    .fill.split .seg:last-child{border-right:0}

    .tag{display:inline-block;padding:0 6px;border-radius:999px;font-size:11px;font-weight:650;
      border:1px solid var(--border);color:var(--text-secondary);margin-left:6px}
    .tag.bad{color:var(--critical);border-color:var(--critical)}

    .empty{text-align:center;padding:36px 16px;color:var(--text-secondary);font-size:14px}
    svg{display:block;width:100%;height:auto}
    /* Below ~560px the chart would shrink its labels past legibility, so it
       keeps a minimum width and scrolls sideways inside its card instead. */
    .chart{overflow-x:auto;-webkit-overflow-scrolling:touch}
    .plot{position:relative;min-width:560px}
    .axis{fill:var(--muted);font-size:11px}

    /* Hover popovers. CSS only: the CSP allows no script. A column's target
       is its whole band; tapping works too, via tabindex="-1" and :focus. */
    .hits{position:absolute;inset:0}
    .col{position:absolute;border-radius:4px;outline:none;cursor:default}
    .col:hover,.col:focus{background:color-mix(in srgb,var(--text-primary) 6%,transparent)}
    .col .tip{top:0;left:calc(100% + 6px)}
    .col.flip .tip{left:auto;right:calc(100% + 6px)}
    .tip{display:none;position:absolute;z-index:5;width:max-content;min-width:170px;max-width:260px;
      padding:9px 11px;border-radius:9px;background:var(--surface-1);border:1px solid var(--border);
      box-shadow:0 8px 24px rgba(0,0,0,.22);font-size:12.5px;line-height:1.4;pointer-events:none;text-align:left}
    .col:hover .tip,.col:focus .tip,.row:hover .tip,.row:focus .tip{display:block}
    .tip-title{font-weight:650;color:var(--text-primary);overflow-wrap:anywhere}
    .tip-sub{color:var(--muted);font-size:12px}
    .tip-foot{margin-top:5px}
    .tip-line{display:flex;align-items:center;gap:7px;margin-top:4px;color:var(--text-secondary)}
    .tip-line i{width:9px;height:9px;border-radius:3px;flex:none}
    .tip-line i.none{background:none}
    .tip-line span{flex:1}
    .tip-line b{color:var(--text-primary);font-weight:650;font-variant-numeric:tabular-nums;white-space:nowrap}
    .tip-line em{font-style:normal;font-weight:400;color:var(--muted);margin-left:6px}
    .tip-total{border-top:1px solid var(--border);padding-top:4px;margin-top:6px}
    .tip.many{max-width:min(440px,calc(100vw - 40px))}
    .tip-grid{display:grid;grid-auto-flow:column;grid-template-columns:repeat(2,minmax(0,1fr));column-gap:18px}
    .tip.many .tip-line{margin-top:3px;min-width:150px}
    /* A row's popover opens under the end of its bar, kept inside the row. */
    .row{position:relative;outline:none}
    .row .pop{position:absolute;left:0;right:0;top:100%}
    .row .tip{top:4px;width:240px;max-width:100%;left:clamp(0px,calc(var(--at) - 120px),calc(100% - 240px))}
    .row .tip.many{width:420px;left:clamp(0px,calc(var(--at) - 210px),calc(100% - 420px))}
    .row:hover .track,.row:focus .track{background:var(--baseline)}

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
