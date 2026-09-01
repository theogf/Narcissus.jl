# ═══════════════════════════════════════════════════════════════════════
# Precompilation ── pay for the first frame at build time, not at 3am
# ═══════════════════════════════════════════════════════════════════════

# The first call to `narcissus` compiles the whole stack: the decomposition
# interface, the node tree, both formatters, the widget's render loop and the
# key handlers. That is a couple of seconds of staring at a blank terminal.
# Running a whole app — a real render into a real Buffer, plus the keys a user
# presses in the first few seconds — moves it into the precompile image.
#
# Nothing here touches a terminal: `Buffer`/`Frame` are plain in-memory
# structures, so this is safe on a headless build machine.

@compile_workload begin
    struct _PLeaf
        α::Float64
        label::String
    end

    mutable struct _PRoot
        name::String
        leaf::_PLeaf
        data::Vector{Float64}
        table::Matrix{Float64}
        tags::Dict{Symbol,Int}
        members::Set{Int}
        pair::Tuple{Int,String}
        named::NamedTuple{(:a, :b),Tuple{Int,Float64}}
    end

    sample() = _PRoot(
        "run",
        _PLeaf(0.5, "hi"),
        [1.0, 2.0, 3.0],
        [1.0 2.0; 3.0 4.0],
        Dict(:a => 1, :b => 2),
        Set([1, 2]),
        (1, "two"),
        (a = 1, b = 2.0),
    )

    other() = _PRoot(
        "run2",
        _PLeaf(0.25, "hi"),
        [1.0, 2.0],
        [1.0 2.0; 3.0 5.0],
        Dict(:a => 1, :c => 3),
        Set([2, 3]),
        (1, "two"),
        (a = 2, b = 2.0),
    )

    rect = Rect(1, 1, 100, 30)

    function _drive(model)
        buffer = Buffer(rect)
        frame = Frame(buffer, rect, GraphicsRegion[], PixelSnapshot[])
        view(model, frame)
        for key in (:down, :right, :left, :up, :pagedown, :end_key, :home, :tab)
            update!(model, KeyEvent(key))
            view(model, frame)
        end
        for char in ('j', 'k', 'l', 'h', 'e', 'c', 'm', 'r', 'd', 'g', 'G', '?', '/')
            update!(model, KeyEvent(char))
            view(model, frame)
        end
        update!(model, KeyEvent(:escape))
        update!(model, MouseEvent(4, 3, mouse_left, mouse_press, false, false, false))
        view(model, frame)
        model
    end

    # Exploring one object, in both views.
    root = root_node(sample(), "obj")
    expand_recursive!(root, 2)
    _drive(Explorer(; tree = ObjectTree(root)))

    fields = root_node(sample(), "obj"; mode = Fields())
    expand_recursive!(fields, 1)
    _drive(Explorer(; tree = ObjectTree(fields)))

    # Comparing two, which is where the equality machinery gets specialised.
    diff = root_node(Diff(sample(), other()), "left")
    expand_differences!(diff, 4)
    _drive(Explorer(; tree = ObjectTree(diff), names = ("left", "right")))

    # The app loop itself: terminal setup, the frame timer, key decoding, the
    # buffer diff that turns a frame into escape codes, and teardown. Nothing
    # else here reaches any of it, and on a cold session it is by far the
    # longest part of the wait between `narcissus(x)` and a first screen.
    #
    # Headless, so a build machine is fine: `io` takes the frames and `input`
    # the keystrokes, so no terminal is opened and fd 0 is never dup'd. The
    # active project is pointed at a scratch directory first because the loop
    # saves its pane split through Preferences on the way out, and a package
    # build has no business writing to the project that triggered it.
    #
    # Wrapped, because a workload that throws takes the whole package down with
    # it: on a platform where this cannot run, the cost is a slower first frame
    # and nothing else.
    try
        mktempdir() do dir
            project = Base.active_project()
            try
                Base.set_active_project(joinpath(dir, "Project.toml"))
                presses = Base.BufferStream()
                # Escape is deliberately not among them: a lone escape byte
                # starts a sequence the decoder then completes with whatever
                # follows, eating the `q` and leaving the loop to the watchdog.
                write(presses, "jl?xq")      # step in, help, close it, quit
                model = Explorer(; tree = ObjectTree(root_node(sample(), "obj")))
                # A build must not be able to hang. `q` ends the loop in the
                # ordinary case; the watchdog sets the same flag the key sets,
                # so a version that reads keys differently costs ten seconds
                # rather than wedging the precompilation forever.
                watchdog = Timer(_ -> (model.quit = true), 10)
                try
                    app(
                        model;
                        io = IOBuffer(),
                        input = presses,
                        tty_size = (rows = 30, cols = 100),
                    )
                finally
                    close(watchdog)
                    close(presses)
                end
            finally
                Base.set_active_project(project)
            end
        end
    catch
    end

    # Elision, cycles, and the awkward leaf values.
    long = root_node(collect(1:500), "v"; limit = 20)
    toggle!(long)
    toggle!(last(long.children))
    for value in (nothing, missing, "text", :sym, 1:5, Int, [Ref(1)])
        node = root_node(value, "v")
        expand_recursive!(node, 1)
        for row in flatten(node)
            preview(row.node)
            node_text(row.node)
            detail_spans(row.node, 40)
        end
    end
end
