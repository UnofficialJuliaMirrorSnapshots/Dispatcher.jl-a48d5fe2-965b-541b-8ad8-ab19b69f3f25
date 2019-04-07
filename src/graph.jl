"""
`DispatchGraph` wraps a directed graph from `LightGraphs` and a bidirectional
dictionary mapping between `DispatchNode` instances and vertex numbers in the
graph.
"""
mutable struct DispatchGraph
    graph::DiGraph  # from LightGraphs
    nodes::NodeSet
end

"""
    DispatchGraph() -> DispatchGraph

Create an empty `DispatchGraph`.
"""
DispatchGraph() = DispatchGraph(DiGraph(), NodeSet())

"""
    DispatchGraph(output_nodes, input_nodes=[]) -> DispatchGraph

Construct a `DispatchGraph` starting from `input_nodes` and ending in `output_nodes`.
The graph is created by recursively identifying dependencies of nodes starting with
`output_nodes` and ending with `input_nodes` (dependencies of `input_nodes` are not added to
the graph).
"""
function DispatchGraph(
    output_nodes::AbstractArray{T},
    input_nodes::Union{AbstractArray{S}, Base.AbstractSet{S}}=DispatchNode[],
) where {T<:DispatchNode, S<:DispatchNode}
    graph = DispatchGraph()
    to_visit = typed_stack(DispatchNode)

    # this is an ObjectIdDict to avoid a hashing stack overflow when there are cycles
    visited = _IdDict()
    for node in output_nodes
        push!(graph, node)
        push!(to_visit, node)
    end

    while !isempty(to_visit)
        curr = pop!(to_visit)

        if !(curr in keys(visited) || curr in input_nodes)
            dep_nodes = dependencies(curr)
            for dep_node in dep_nodes
                push!(to_visit, dep_node)
                push!(graph, dep_node)
                add_edge!(graph, dep_node, curr)
            end
        end

        visited[curr] = nothing
    end

    return graph
end

"""
    DispatchGraph(output_node) -> DispatchGraph

Construct a `DispatchGraph` ending in `output_nodes`.
The graph is created by recursively identifying dependencies of nodes starting with
`output_nodes`. This call is equivalent to `DispatchGraph([output_node])`.
"""
DispatchGraph(output_node::DispatchNode) = DispatchGraph([output_node])

"""
    show(io::IO, graph::DispatchGraph)

Print a simplified string representation of the `DispatchGraph` with its graph and nodes.
"""
function Base.show(io::IO, graph::DispatchGraph)
    print(io, typeof(graph).name.name, "($(graph.graph),$(graph.nodes))")
end

"""
    length(graph::DispatchGraph) -> Integer

Return the number of nodes in the graph.
"""
Base.length(graph::DispatchGraph) = length(graph.nodes)

"""
    push!(graph::DispatchGraph, node::DispatchNode) -> DispatchGraph

Add a node to the graph and return the graph.
"""
function Base.push!(graph::DispatchGraph, node::DispatchNode)
    push!(graph.nodes, node)
    node_number = graph.nodes[node]
    add_vertices!(graph.graph, clamp(node_number - nv(graph.graph), 0, node_number))
    return graph
end

"""
    add_edge!(graph::DispatchGraph, parent::DispatchNode, child::DispatchNode) -> Bool

Add an edge to the graph from `parent` to `child`.
Return whether the operation was successful.
"""
function LightGraphs.add_edge!(
    graph::DispatchGraph,
    parent::DispatchNode,
    child::DispatchNode,
)
    add_edge!(graph.graph, graph.nodes[parent], graph.nodes[child])
end

"""
    nodes(graph::DispatchGraph) ->

Return an iterable of all nodes stored in the `DispatchGraph`.
"""
nodes(graph::DispatchGraph) = nodes(graph.nodes)

"""
    inneighbors(graph::DispatchGraph, node::DispatchNode) ->

Return an iterable of all nodes in the graph with edges from themselves to `node`.
"""
function LightGraphs.inneighbors(graph::DispatchGraph, node::DispatchNode)
    imap(n->graph.nodes[n], inneighbors(graph.graph, graph.nodes[node]))
end

"""
    outneighbors(graph::DispatchGraph, node::DispatchNode) ->

Return an iterable of all nodes in the graph with edges from `node` to themselves.
"""
function LightGraphs.outneighbors(graph::DispatchGraph, node::DispatchNode)
    imap(n->graph.nodes[n], outneighbors(graph.graph, graph.nodes[node]))
end

"""
    leaf_nodes(graph::DispatchGraph) ->

Return an iterable of all nodes in the graph with no outgoing edges.
"""
function leaf_nodes(graph::DispatchGraph)
    imap(n->graph.nodes[n], filter(1:nv(graph.graph)) do node_index
        outdegree(graph.graph, node_index) == 0
    end)
end

# vs is an Int iterable
function LightGraphs.induced_subgraph(graph::DispatchGraph, vs)
    new_graph = DispatchGraph()

    for keep_id in vs
        add_vertex!(new_graph.graph)
        push!(new_graph.nodes, graph.nodes[keep_id])
    end

    for keep_id in vs
        for vc in outneighbors(graph.graph, keep_id)
            if vc in vs
                add_edge!(
                    new_graph.graph,
                    new_graph.nodes[graph.nodes[keep_id]],
                    new_graph.nodes[graph.nodes[vc]],
                )
            end
        end
    end

    return new_graph
end

"""
    graph1::DispatchGraph == graph2::DispatchGraph

Determine whether two graphs have the same nodes and edges.
This is an expensive operation.
"""
function Base.:(==)(graph1::DispatchGraph, graph2::DispatchGraph)
    if length(graph1) != length(graph2)
        return false
    end

    nodes1 = Set{DispatchNode}(nodes(graph1))

    if nodes1 != Set{DispatchNode}(nodes(graph2))
        return false
    end

    for node in nodes1
        if Set{DispatchNode}(outneighbors(graph1, node)) !=
                Set{DispatchNode}(outneighbors(graph2, node))
            return false
        end
    end

    return true
end

"""
    subgraph(graph::DispatchGraph, endpoints, roots) -> DispatchGraph

Return a new `DispatchGraph` containing everything "between" `roots` and `endpoints`
(arrays of `DispatchNode`s), plus everything else necessary to generate `endpoints`.

More precisely, only `endpoints` and the ancestors of `endpoints`, without any
nodes which are ancestors of `endpoints` only through `roots`.
If `endpoints` is empty, return a new `DispatchGraph` containing only `roots`, and nodes
which are decendents from nodes which are not descendants of `roots`.
"""
function subgraph(
    graph::DispatchGraph,
    endpoints::AbstractArray{T},
    roots::AbstractArray{S}=DispatchNode[],
) where {T<:DispatchNode, S<:DispatchNode}
    endpoint_ids = Int[graph.nodes[e] for e in endpoints]
    root_ids = Int[graph.nodes[i] for i in roots]

    return subgraph(graph, endpoint_ids, root_ids)
end

function subgraph(
    graph::DispatchGraph,
    endpoints::AbstractArray{Int},
    roots::AbstractArray{Int}=Int[],
)
    to_visit = typed_stack(Int)

    if isempty(endpoints)
        rootset = Set{Int}(roots)
        discards = Set{Int}()

        for v in roots
            for vp in inneighbors(graph.graph, v)
                push!(to_visit, vp)
            end
        end

        while length(to_visit) > 0
            v = pop!(to_visit)

            if all((vc in rootset || vc in discards) for vc in outneighbors(graph.graph, v))
                push!(discards, v)

                for vp in inneighbors(graph.graph, v)
                    push!(to_visit, vp)
                end
            end
        end

        keeps = setdiff(1:nv(graph.graph), discards)
    else
        keeps = Set{Int}()

        union!(keeps, roots)

        for v in endpoints
            if !(v in keeps)
                push!(to_visit, v)
            end
        end

        while length(to_visit) > 0
            v = pop!(to_visit)

            for vp in inneighbors(graph.graph, v)
                if !(vp in keeps)
                    push!(to_visit, vp)
                end
            end

            push!(keeps, v)
        end
    end

    return induced_subgraph(graph, keeps)
end
