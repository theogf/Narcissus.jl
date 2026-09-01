@testsnippet AppHarness begin
    using Tachikoma
    using Narcissus:
        Explorer,
        ObjectTree,
        root_node,
        current_node,
        selected_value,
        invalidate!,
        rows,
        node_text,
        search!,
        toggle!
    import Tachikoma: view, update!

    "Render a model into a TestBackend so its screen can be inspected."
    function draw(m, width::Int = 90, height::Int = 20)
        rect = Rect(1, 1, width, height)
        buf = Buffer(rect)
        view(m, Frame(buf, rect, GraphicsRegion[], PixelSnapshot[]))
        tb = TestBackend(width, height)
        tb.buf.content .= buf.content
        tb
    end

    screen(tb) = join((row_text(tb, y) for y = 1:tb.height), "\n")

    press!(m, k) = (update!(m, KeyEvent(k)); m)

    """
    Draw until the model's background measurements have all landed, the way the
    app loop would over a few frames.
    """
    function settle!(m, width = 90, height = 20; frames = 200)
        for _ = 1:frames
            # A draw both asks for work and dispatches it, capped — so the
            # signal that everything has landed is a draw that asks for nothing.
            draw(m, width, height)
            isempty(m.in_flight) && return m
            sleep(0.005)
            drain_tasks!(e -> update!(m, e), m.work)
        end
        m
    end

    struct Config
        lr::Float64
        tags::Vector{Symbol}
    end

    mutable struct Run
        name::String
        config::Config
        losses::Vector{Float64}
    end

    sample_run() = Run("exp-1", Config(0.01, [:fast, :noisy]), [3.0, 2.0, 1.0])

    explorer(obj, name = "run"; kwargs...) =
        Explorer(; tree = ObjectTree(root_node(obj, name; kwargs...)))
end

@testitem "the explorer renders both panes" tags=[:unit] setup=[AppHarness] begin
    m = explorer(sample_run())
    s = screen(draw(m))
    @test occursin("object", s)
    @test occursin("detail", s)
    @test occursin("run::", s) && occursin("Run", s)
    @test occursin("path", s)
    @test occursin("q quit", s)
end

@testitem "arrow keys walk into the object" tags=[:unit] setup=[AppHarness] begin
    m = explorer(sample_run())
    press!(m, :right)                      # expand the root
    @test length(rows(m.tree)) == 4
    press!(m, :down)
    press!(m, :down)     # onto `config`
    @test current_node(m.tree).key == "config"
    press!(m, :right)                      # into it
    press!(m, :down)
    @test current_node(m.tree).path == "run.config.lr"
    @test selected_value(m) == 0.01

    press!(m, :left)                       # back out to the parent
    @test current_node(m.tree).key == "config"
end

@testitem "vim keys mirror the arrows" tags=[:unit] setup=[AppHarness] begin
    m = explorer(sample_run())
    press!(m, 'l')
    press!(m, 'j')
    press!(m, 'j')
    press!(m, 'l')
    @test current_node(m.tree).key == "config"
    @test current_node(m.tree).expanded
    press!(m, 'h')
    @test !current_node(m.tree).expanded
    press!(m, 'G')
    @test current_node(m.tree) === last(rows(m.tree)).node
    press!(m, 'g')
    @test m.tree.selected == 1
end

@testitem "search jumps to a matching row" tags=[:unit] setup=[AppHarness] begin
    m = explorer(sample_run())
    press!(m, 'e')                          # expand a couple of levels
    press!(m, '/')
    @test m.searching
    for c in "noisy"
        press!(m, c)
    end
    press!(m, :enter)
    @test !m.searching
    @test m.tree.query == "noisy"
    @test occursin("noisy", node_text(current_node(m.tree)))

    press!(m, :escape)                      # first escape only clears the search
    @test isempty(m.tree.query)
    @test !m.quit
end

@testitem "elided rows load the next window" tags=[:unit] setup=[AppHarness] begin
    m = explorer(collect(1:250), "v"; limit = 100)
    press!(m, :right)
    @test length(rows(m.tree)) == 102
    press!(m, 'G')                          # onto the `…` row
    @test current_node(m.tree).kind === :elided
    press!(m, :enter)
    @test length(rows(m.tree)) == 202
    @test occursin("50 more", node_text(last(rows(m.tree)).node))
end

@testitem "focus moves to the detail pane" tags=[:unit] setup=[AppHarness] begin
    m = explorer(collect(1:400), "v")
    draw(m)                                  # populate the detail pane
    press!(m, :tab)
    @test m.focus === :detail
    press!(m, :down)
    press!(m, :down)
    draw(m)
    @test m.detail_offset > 0
    press!(m, 'g')
    @test m.detail_offset == 0

    # The layout is cached: drawing again does not rebuild it.
    before = m.detail
    draw(m)
    @test m.detail === before
end

@testitem "help overlay opens and any key closes it" tags=[:unit] setup=[AppHarness] begin
    m = explorer(sample_run())
    press!(m, '?')
    @test m.show_help
    s = screen(draw(m))
    @test occursin("keys", s)
    @test occursin("copy the path expression", s)
    press!(m, :escape)
    @test !m.show_help
    @test !m.quit
end

@testitem "quitting returns the selected value" tags=[:unit] setup=[AppHarness] begin
    r = sample_run()
    m = explorer(r)
    press!(m, :right)
    press!(m, :down)
    @test selected_value(m) == "exp-1"
    press!(m, 'q')
    @test Narcissus.should_quit(m)
end

@testitem "reload picks up mutation" tags=[:unit] setup=[AppHarness] begin
    r = sample_run()
    m = explorer(r)
    press!(m, :right)
    press!(m, :down)
    @test occursin("exp-1", node_text(current_node(m.tree)))

    r.name = "exp-2"
    press!(m, 'r')
    @test occursin("exp-2", node_text(current_node(m.tree)))
    @test m.notice == "reloaded"
end

@testitem "mouse clicks select and toggle" tags=[:unit] setup=[AppHarness] begin
    m = explorer(sample_run())
    draw(m)
    click(x, y) = update!(m, MouseEvent(x, y, mouse_left, mouse_press, false, false, false))
    click(4, 2)                              # the row already under the cursor
    @test m.tree.selected == 1
    @test m.tree.root.expanded               # ... so the click toggled it open
    @test length(rows(m.tree)) == 4

    draw(m)
    click(4, 4)                              # a different row: select only
    @test m.tree.selected == 3
    @test !current_node(m.tree).expanded
    click(4, 4)                              # click again to open it
    @test current_node(m.tree).expanded
end

@testitem "degenerate terminal sizes do not throw" tags=[:unit] setup=[AppHarness] begin
    m = explorer(sample_run())
    for (w, h) in ((6, 3), (10, 5), (20, 6), (200, 60))
        @test draw(m, w, h) isa TestBackend
    end
end

@testitem "m switches a row between its two views" tags=[:unit] setup=[AppHarness] begin
    using Narcissus: Semantic, Fields

    m = explorer(Dict(:a => 1, :b => 2), "d")
    press!(m, :right)
    @test length(rows(m.tree)) == 3               # the two entries
    @test occursin(":a", screen(draw(m)))

    press!(m, 'm')
    @test current_node(m.tree).mode isa Fields
    @test m.notice == "d: fields view"
    s = screen(draw(m))
    @test occursin("slots", s)                    # storage, not entries
    @test occursin("·fields", s)                  # the row says so
    @test occursin("m: semantic", s)              # and so does the detail pane

    press!(m, 'm')
    @test current_node(m.tree).mode isa Semantic
    @test occursin(":a", screen(draw(m)))
end

@testitem "m says so when there is one view" tags=[:unit] setup=[AppHarness] begin
    m = explorer(sample_run())
    press!(m, 'm')
    @test m.notice == "run has only one view"
    @test !occursin("·fields", screen(draw(m)))
end

@testitem "field-mode paths stay pasteable" tags=[:unit] setup=[AppHarness] begin
    # A Dict rather than a Vector: Array exposes no fields before Julia 1.11.
    m = explorer(Dict(:a => 1), "d")
    press!(m, 'm')
    press!(m, :right)
    press!(m, :down)
    @test current_node(m.tree).path == "d.slots"
end

@testitem "comparison marks and navigates diffs" tags=[:unit] setup=[AppHarness] begin
    using Narcissus: Diff, Explorer, ObjectTree, root_node, expand_differences!, node_status

    before = sample_run()
    after = sample_run()
    after.losses = [3.0, 2.0, 0.5]

    root = root_node(Diff(before, after), "before")
    root.key = "before ⇄ after"
    expand_differences!(root, 8)
    m = Explorer(; tree = ObjectTree(root), names = ("before", "after"))

    s = screen(draw(m))
    @test occursin("comparison", s)          # the pane says what it is
    @test occursin("next diff", s)           # and the status bar offers `d`
    @test occursin("→", s)                   # changed rows show both sides

    # `d` walks the differing rows and skips the identical ones.
    press!(m, 'd')
    @test node_status(current_node(m.tree)) !== :same
    seen = String[]
    for _ = 1:4
        press!(m, 'd')
        push!(seen, current_node(m.tree).path)
        @test node_status(current_node(m.tree)) !== :same
    end
    @test "before.losses[3]" in seen

    # The detail pane addresses both sides by name.
    d = screen(draw(m))
    @test occursin("before", d) && occursin("after", d)
    @test occursin("status", d)
end

@testitem "d does nothing outside a comparison" tags=[:unit] setup=[AppHarness] begin
    m = explorer(sample_run())
    press!(m, 'd')
    @test occursin("not comparing", m.notice)
end

@testitem "identical objects say so" tags=[:unit] setup=[AppHarness] begin
    using Narcissus: Diff, Explorer, ObjectTree, root_node, expand_differences!

    a = sample_run()
    root = root_node(Diff(a, deepcopy(a)), "a")
    expand_differences!(root, 8)
    m = Explorer(; tree = ObjectTree(root), names = ("a", "b"))
    @test length(rows(m.tree)) == 1
    @test occursin("identical", screen(draw(m)))
end

@testitem "search escalates into what is not loaded" tags=[:unit] setup=[AppHarness] begin
    m = explorer(sample_run())
    @test length(rows(m.tree)) == 1                # nothing opened yet

    press!(m, '/')
    for c in "noisy"
        press!(m, c)
    end
    press!(m, :enter)

    @test occursin("found in", m.notice)
    @test current_node(m.tree).path == "run.config.tags[2]"
    # It opened the path to the match and nothing else.
    @test length(rows(m.tree)) <= 8
    @test occursin("noisy", screen(draw(m)))
end

@testitem "a search with no match says so" tags=[:unit] setup=[AppHarness] begin
    m = explorer(sample_run())
    press!(m, '/')
    for c in "zzzz"
        press!(m, c)
    end
    press!(m, :enter)
    @test occursin("no match", m.notice)
end

@testitem "a hunts anomalies and keeps going" tags=[:unit] setup=[AppHarness] begin
    using Narcissus: node_anomaly

    r = sample_run()
    r.losses = [3.0, NaN, 1.0]
    m = explorer((run = r, spare = Float64[]), "s")

    press!(m, 'a')
    first_hit = current_node(m.tree).path
    @test node_anomaly(current_node(m.tree)) !== nothing

    press!(m, 'a')
    @test current_node(m.tree).path != first_hit   # it moved on
    @test node_anomaly(current_node(m.tree)) !== nothing

    @test occursin("!", screen(draw(m)))           # the flag column is drawn
end

@testitem "a says so when nothing is suspicious" tags=[:unit] setup=[AppHarness] begin
    m = explorer(sample_run())
    press!(m, 'a')
    @test occursin("nothing suspicious", m.notice)
end

@testitem "M shows what each row costs" tags=[:unit] setup=[AppHarness] begin
    m = explorer((small = [1, 2], big = rand(20_000)), "s")
    press!(m, :right)

    press!(m, 'M')
    @test m.tree.show_memory
    @test occursin("retained size", m.notice)

    # Measuring happens off the main task, so the first frame shows placeholders.
    @test occursin("…", screen(draw(m, 120, 12)))

    settle!(m, 120, 12)
    s = screen(draw(m, 120, 12))
    @test occursin("KiB", s)
    @test occursin("%", s)
    @test occursin("▕", s)                          # the share bar

    press!(m, 'M')
    @test !m.tree.show_memory
    @test !occursin("KiB", screen(draw(m, 120, 12)))
end

@testitem "f folds away what matched" tags=[:unit] setup=[AppHarness] begin
    using Narcissus: Diff, Explorer, ObjectTree, root_node, expand_differences!, node_status

    before = sample_run()
    after = sample_run()
    after.losses = [3.0, 2.0, 0.5]

    root = root_node(Diff(before, after), "before")
    expand_differences!(root, 8)
    m = Explorer(; tree = ObjectTree(root), names = ("before", "after"))

    full = length(rows(m.tree))
    @test any(r -> node_status(r.node) === :same, rows(m.tree))

    press!(m, 'f')
    @test m.tree.hide_same
    @test length(rows(m.tree)) < full
    @test !any(r -> node_status(r.node) === :same, rows(m.tree))

    press!(m, 'f')
    @test length(rows(m.tree)) == full
end

@testitem "the comparison pane tallies what differs" tags=[:unit] setup=[AppHarness] begin
    using Narcissus: Diff, Explorer, ObjectTree, root_node, expand_differences!

    before = sample_run()
    after = sample_run()
    after.losses = [3.0, 2.0, 0.5, 0.1]

    root = root_node(Diff(before, after), "before")
    expand_differences!(root, 8)
    m = Explorer(; tree = ObjectTree(root), names = ("before", "after"))

    s = screen(draw(m))
    @test occursin("~", s)     # changed
    @test occursin("+", s)     # the added element
end

@testitem "modules and types open in the app" tags=[:unit] setup=[AppHarness] begin
    m = explorer(Narcissus, "Narcissus")
    press!(m, :right)
    s = screen(draw(m))
    @test occursin("narcissus", s)
    @test occursin("module", screen(draw(m)))

    t = explorer(Config, "Config")
    press!(t, :right)
    s2 = screen(draw(t))
    @test occursin("lr", s2)
    @test occursin("Float64", s2)
    @test occursin("::type", s2)
end

@testitem "f filters a module listing by kind" tags=[:unit] setup=[AppHarness] begin
    using Narcissus: binding_kind, cycle_kinds!, in_module

    m = explorer(Narcissus, "Narcissus")
    press!(m, :right)
    everything = length(rows(m.tree))
    @test in_module(m.tree)

    press!(m, 'f')
    @test m.tree.kinds === :function
    @test occursin("functions", m.notice)
    @test all(
        r -> r.node.value isa Module || binding_kind(r.node.value) === :function,
        rows(m.tree),
    )
    @test length(rows(m.tree)) < everything
    @test occursin("functions only", screen(draw(m)))

    press!(m, 'f')
    @test m.tree.kinds === :macro
    @test all(
        r -> r.node.value isa Module || binding_kind(r.node.value) === :macro,
        rows(m.tree),
    )

    press!(m, 'f')
    @test m.tree.kinds === :type
    @test all(
        r -> r.node.value isa Module || binding_kind(r.node.value) === :type,
        rows(m.tree),
    )

    press!(m, 'f')
    press!(m, 'f')
    press!(m, 'f')
    @test m.tree.kinds === :all                     # back around
    @test length(rows(m.tree)) == everything
end

@testitem "f says so where there is nothing to narrow" tags=[:unit] setup=[AppHarness] begin
    m = explorer(sample_run())
    press!(m, 'f')
    @test occursin("nothing to filter", m.notice)
end

@testitem "a function shows its methods and its docs" tags=[:unit] setup=[AppHarness] begin
    m = explorer(Narcissus.components, "components")
    press!(m, :right)
    @test length(rows(m.tree)) > 1
    @test all(r -> r.node.value isa Method, rows(m.tree)[2:end])

    s = screen(draw(m, 110, 24))
    @test occursin("methods", s)
    @test occursin("List the parts of", s)        # the rendered docstring
end

@testitem "a slow value spins instead of blocking the frame" tags=[:unit] setup=[AppHarness] begin
    using Narcissus: SPINNER, measure, compute_preview, preview, set_preview!

    # No preview yet, and the frame budget already spent: the row draws a
    # spinner and asks for the value to be rendered somewhere else.
    m = explorer([1, 2, 3], "v")
    press!(m, :right)
    node = rows(m.tree)[2].node
    node._preview = nothing
    m.tree.pending = Tuple{Narcissus.ObjNode,Symbol}[]

    # What the renderer would hand to a background task, and what comes back.
    @test measure(:preview, node) == compute_preview(node)
    @test node._preview === nothing          # computing it off-thread stores nothing
    set_preview!(node, "from a task")
    @test preview(node) == "from a task"

    @test length(SPINNER) > 1
    @test Narcissus.spinner_char(0) != Narcissus.spinner_char(4)
    @test Narcissus.spinner_char(0) == Narcissus.spinner_char(4 * length(SPINNER))
end

@testitem "the memory column is right-aligned" tags=[:unit] setup=[AppHarness] begin
    m = explorer((small = [1, 2], big = rand(20_000)), "s")
    press!(m, :right)
    press!(m, 'M')
    settle!(m, 100, 8)

    tb = draw(m, 100, 8)
    # Character positions, not byte offsets — the box-drawing characters around
    # the panes are multi-byte and would make aligned columns look ragged.
    columns = [findlast(==('%'), collect(row_text(tb, y))) for y = 2:4]
    @test all(!isnothing, columns)
    @test length(unique(columns)) == 1             # every % in the same column
end

@testitem "slow measurements happen off the main task" tags=[:unit] setup=[AppHarness] begin
    using Narcissus: bytes_state, anomaly_state, MAX_IN_FLIGHT

    m = explorer((big = rand(200_000), also = rand(200_000), tag = "x"), "s")
    press!(m, :right)
    press!(m, 'M')

    # The first frame draws placeholders and asks for the work; it does not do it.
    draw(m, 100, 10)
    @test all(r -> bytes_state(r.node) < 0, rows(m.tree))
    @test occursin("…", screen(draw(m, 100, 10)))
    @test !isempty(m.in_flight)
    @test length(m.in_flight) <= MAX_IN_FLIGHT      # capped, not a stampede

    settle!(m, 100, 10)
    @test isempty(m.in_flight)
    @test all(r -> bytes_state(r.node) >= 0, rows(m.tree))
    # Every tree row now carries a real measurement rather than a placeholder.
    tb = draw(m, 100, 10)
    @test all(y -> occursin('%', row_text(tb, y)), 2:5)
    @test occursin("MiB", screen(tb))
end

@testitem "anomaly flags arrive without blocking the frame" tags=[:unit] setup=[AppHarness] begin
    using Narcissus: anomaly_state

    losses = rand(200_000)
    losses[100_000] = NaN
    m = explorer((losses = losses, fine = rand(200_000)), "s")
    press!(m, :right)

    draw(m, 90, 10)
    @test any(r -> anomaly_state(r.node) === :pending, rows(m.tree))
    # Nothing is flagged yet, so no column is reserved and nothing has shifted.
    @test !occursin("!", screen(draw(m, 90, 10)))

    settle!(m, 90, 10)
    @test anomaly_state(rows(m.tree)[2].node) === :nan
    @test occursin("!", screen(draw(m, 90, 10)))
end
