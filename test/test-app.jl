@testsnippet AppLoop begin
    using Tachikoma
    using Narcissus: Explorer, ObjectTree, root_node, Diff, expand_differences!,
                     current_node, rows

    struct Layer
        weights::Matrix{Float64}
        act::Symbol
    end

    mutable struct Net
        name::String
        layers::Vector{Layer}
        opts::Dict{Symbol,Any}
        losses::Vector{Float64}
    end

    sample_net(name="net") = Net(name,
        [Layer([1.0 2.0; 3.0 4.0], :relu), Layer([0.5 0.1], :σ)],
        Dict{Symbol,Any}(:lr => 0.01, :epochs => 100),
        [3.0, 2.0, 1.0])

    "Run a model through Tachikoma's real event loop, headlessly."
    function run_app(model, script; width=100, height=28, frames=90, fps=30)
        out = record_app(model, tempname() * ".tach";
                         width, height, frames, fps, events=script(fps))
        (; file=out, model)
    end
end

@testitem "the real event loop drives the explorer" tags=[:integration] setup=[AppLoop] begin
    model = Explorer(; tree = ObjectTree(root_node(sample_net(), "net")))

    # A plausible few seconds of use, through `app`'s own loop rather than
    # `update!` and `view` called by hand.
    script = EventScript(
        (0.2, key(:right)), (0.1, key(:down)), (0.1, key(:down)),
        (0.1, key(:right)), (0.1, key(:down)),
        (0.1, key('e')), (0.1, key('c')),
        (0.1, key('m')), (0.1, key('m')),
        (0.1, key('M')), (0.1, key('M')),
        (0.1, key('a')),
        (0.1, key('/')), chars("opts"; pace=0.05), (0.1, key(:enter)),
        (0.1, key('n')), (0.1, key('y')),
        (0.1, key(:tab)), (0.1, key(:pagedown)), (0.1, key(:tab)),
        (0.1, key('?')), (0.3, key(:escape)),
        (0.1, key('g')), (0.1, key('G')),
    )

    result = run_app(model, script)
    @test isfile(result.file)
    @test filesize(result.file) > 0
    @test !Narcissus.should_quit(model)          # nothing quit it early
    @test current_node(model.tree) !== nothing
    rm(result.file; force=true)
end

@testitem "the real loop drives a comparison" tags=[:integration] setup=[AppLoop] begin
    before = sample_net("before")
    after = sample_net("after")
    after.losses = [3.0, 2.0, 0.5]
    after.opts[:lr] = 0.001

    root = root_node(Diff(before, after), "before")
    root.key = "before ⇄ after"
    expand_differences!(root, 8)
    model = Explorer(; tree = ObjectTree(root), names = ("before", "after"))

    script = EventScript(
        (0.2, key('d')), (0.1, key('d')), (0.1, key('D')),
        (0.1, key('f')), (0.2, key('f')),
        (0.1, key('m')), (0.1, key('m')),
        (0.1, key(:right)), (0.1, key(:left)),
        (0.1, key('Y')),
    )

    result = run_app(model, script)
    @test isfile(result.file)
    @test !Narcissus.should_quit(model)
    @test length(rows(model.tree)) > 1
    rm(result.file; force=true)
end

@testitem "q quits through the real loop" tags=[:integration] setup=[AppLoop] begin
    model = Explorer(; tree = ObjectTree(root_node(sample_net(), "net")))
    result = run_app(model, EventScript((0.2, key(:right)), (0.2, key('q')));
                     frames=30)
    @test Narcissus.should_quit(model)
    rm(result.file; force=true)
end

@testitem "the panes resize by dragging the border" tags=[:unit] setup=[AppLoop] begin
    using Narcissus: Explorer, ObjectTree, root_node
    import Tachikoma: view, update!

    model = Explorer(; tree = ObjectTree(root_node(sample_net(), "net")))
    function paint!(m, w=100, h=20)
        rect = Rect(1, 1, w, h)
        view(m, Frame(Buffer(rect), rect, GraphicsRegion[], PixelSnapshot[]))
        [r.width for r in m.split.rects]
    end

    default = paint!(model)
    border = default[1]

    update!(model, MouseEvent(border, 5, mouse_left, mouse_press, false, false, false))
    update!(model, MouseEvent(border - 15, 5, mouse_left, mouse_drag, false, false, false))
    update!(model,
            MouseEvent(border - 15, 5, mouse_left, mouse_release, false, false, false))
    dragged = paint!(model)
    @test dragged[1] < default[1]
    @test sum(dragged) == sum(default)

    # Right-clicking the border puts it back.
    update!(model, MouseEvent(dragged[1], 5, mouse_right, mouse_press, false, false, false))
    @test paint!(model) == default
end
