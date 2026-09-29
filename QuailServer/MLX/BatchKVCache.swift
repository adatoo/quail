import Foundation
import MLX
import MLXLMCommon

/// An attention layer's cache for several sequences decoded together (ADR D-056): keys and values are
/// `[B, heads, T, dim]`, each sequence left-padded so every sequence's latest token sits in the same column.
/// The model reads each sequence's position from `ropeOffset` and hides the padding through `makeMask`, the two
/// hooks mlx-swift-lm's attention already goes through, so the model code runs unchanged over the batch.
///
/// Sequences join already prefilled (`extend`), one token a step is added for each, and a sequence leaves with
/// `filter`, its own cache handed back by `slice`.
final class BatchKVCache: KVCache {
    private var keys: MLXArray?
    private var values: MLXArray?
    /// Padding columns at the start of each sequence's row.
    private(set) var padding: [Int] = []
    /// Columns in use (the longest sequence's length).
    private var length = 0
    /// Columns added at a time as the batch grows, as `KVCacheSimple` does.
    private static let step = 256

    /// One sequence's cache as the first row.
    init(_ first: KVCacheSimple) {
        let state = first.state
        if state.count == 2 {
            keys = state[0]
            values = state[1]
            length = first.offset
        }
        padding = [0]
    }

    private init() {}

    var batchSize: Int {
        padding.count
    }

    /// Each sequence's own length.
    var lengths: [Int] {
        padding.map { length - $0 }
    }

    // MARK: KVCache

    var offset: Int {
        length
    }

    var maxSize: Int? {
        nil
    }

    /// Each sequence's position: its own token count, not the padded width.
    var ropeOffset: RoPEOffset {
        .batch(MLXArray(padding.map { Int32(length - $0) }))
    }

    func innerState() -> [MLXArray] {
        [keys, values].compactMap(\.self)
    }

    func update(keys newKeys: MLXArray, values newValues: MLXArray) -> (MLXArray, MLXArray) {
        let previous = length
        let added = newKeys.dim(2)
        if keys == nil || previous + added > keys!.dim(2) {
            let columns = (previous + added + Self.step - 1) / Self.step * Self.step
            let grownKeys = MLXArray.zeros(
                [newKeys.dim(0), newKeys.dim(1), columns, newKeys.dim(3)], dtype: newKeys.dtype
            )
            let grownValues = MLXArray.zeros(
                [newValues.dim(0), newValues.dim(1), columns, newValues.dim(3)], dtype: newValues.dtype
            )
            if let keys, let values, previous > 0 {
                grownKeys[.ellipsis, ..<previous, 0...] = keys[.ellipsis, ..<previous, 0...]
                grownValues[.ellipsis, ..<previous, 0...] = values[.ellipsis, ..<previous, 0...]
            }
            keys = grownKeys
            values = grownValues
        }
        length += added
        keys![.ellipsis, previous ..< length, 0...] = newKeys
        values![.ellipsis, previous ..< length, 0...] = newValues
        return (keys![.ellipsis, ..<length, 0...], values![.ellipsis, ..<length, 0...])
    }

    /// Causal, and nothing from a row's padding. Without padding, what the library's own caches return.
    func makeMask(n: Int, windowSize: Int?, returnArray: Bool) -> MLXFast.ScaledDotProductAttentionMaskMode {
        let columns = MLXArray(Int32(0) ..< Int32(length + n)).expandedDimensions(axis: 0)
        var keep: MLXArray?
        if padding.contains(where: { $0 > 0 }) {
            // [B, 1, 1, T + n]: a row sees its own columns only.
            let starts = MLXArray(padding.map { Int32($0) }).expandedDimensions(axis: 1)
            keep = (columns .>= starts).expandedDimensions(axes: [1, 2])
        }
        if n > 1 || windowSize != nil {
            let rows = MLXArray(Int32(length) ..< Int32(length + n)).expandedDimensions(axis: 1)
            var causal = rows .>= columns
            if let windowSize {
                causal = causal & (rows .< columns + MLXArray(Int32(windowSize)))
            }
            keep = keep.map { $0 & causal } ?? (returnArray || windowSize != nil ? causal : nil)
            if keep == nil {
                return .causal
            }
        }
        return keep.map { .array($0) } ?? .none
    }

    var state: [MLXArray] {
        get {
            guard let keys, let values else { return [] }
            return [keys[.ellipsis, ..<length, 0...], values[.ellipsis, ..<length, 0...]]
        }
        set {
            guard newValue.count == 2 else { return }
            keys = newValue[0]
            values = newValue[1]
            length = newValue[0].dim(2)
            padding = Array(repeating: 0, count: newValue[0].dim(0))
        }
    }

    var metaState: [String] {
        get { [""] }
        set {}
    }

    /// Never cut back: a sequence's cache is cut back after it leaves (`slice`), not inside the batch.
    var isTrimmable: Bool {
        false
    }

    @discardableResult
    func trim(_: Int) -> Int {
        0
    }

    func copy() -> any KVCache {
        let new = BatchKVCache()
        new.keys = keys.map { $0[.ellipsis] }
        new.values = values.map { $0[.ellipsis] }
        new.padding = padding
        new.length = length
        return new
    }

    // MARK: Joining and leaving

    /// Adds a prefilled sequence as the last row, padding whichever side is shorter.
    func extend(_ other: KVCacheSimple) {
        // Both sides hold tokens: a sequence joins with its prompt fed.
        let state = other.state
        guard state.count == 2, let keys, let values else { return }
        let otherLength = other.offset
        let width = max(length, otherLength)
        var ownKeys = keys[.ellipsis, ..<length, 0...]
        var ownValues = values[.ellipsis, ..<length, 0...]
        if width > length {
            ownKeys = Self.leftPad(ownKeys, by: width - length)
            ownValues = Self.leftPad(ownValues, by: width - length)
            padding = padding.map { $0 + width - length }
        }
        self.keys = concatenated([ownKeys, Self.leftPad(state[0], by: width - otherLength)], axis: 0)
        self.values = concatenated([ownValues, Self.leftPad(state[1], by: width - otherLength)], axis: 0)
        padding.append(width - otherLength)
        length = width
    }

    /// Keeps only the rows at `indices`, in that order, and drops padding every row now has.
    func filter(_ indices: [Int]) {
        padding = indices.map { padding[$0] }
        let rows = MLXArray(indices.map { Int32($0) })
        keys = keys?[rows]
        values = values?[rows]
        if let shared = padding.min(), shared > 0 {
            keys = keys?[.ellipsis, shared..., 0...]
            values = values?[.ellipsis, shared..., 0...]
            padding = padding.map { $0 - shared }
            length -= shared
        }
    }

    /// Row `index`'s sequence as a cache of its own (a copy, so the batch's arrays can go).
    func slice(_ index: Int) -> KVCacheSimple {
        let cache = KVCacheSimple()
        if let keys, let values, length > padding[index] {
            let rows = index ..< index + 1, columns = padding[index] ..< length
            cache.state = [
                contiguous(keys[rows, 0..., columns, 0...]), contiguous(values[rows, 0..., columns, 0...]),
            ]
        }
        return cache
    }

    private static func leftPad(_ array: MLXArray, by count: Int) -> MLXArray {
        guard count > 0 else { return array }
        var shape = array.shape
        shape[2] = count
        return concatenated([MLXArray.zeros(shape, dtype: array.dtype), array], axis: 2)
    }
}

/// A sliding-window attention layer's cache for several sequences decoded together (Gemma 4, #140): like
/// `BatchKVCache`, rows left-padded so every sequence's latest token sits in the same column, but holding only the
/// window. mlx-swift-lm's `RotatingKVCache` writes its window as a ring; here the columns stay in order and the oldest
/// are dropped `step` at a time once there are more than the window, so a step writes one column and a trim copies
/// the window once every `step` steps. Each sequence's position is its own token count, kept apart from the columns.
final class BatchSlidingKVCache: KVCache {
    private var keys: MLXArray?
    private var values: MLXArray?
    private(set) var padding: [Int] = []
    /// Each sequence's token count, which the window has long passed.
    private(set) var positions: [Int] = []
    /// Columns in use.
    private var width = 0
    let window: Int
    private static let step = 256

    /// One sequence's cache as the first row.
    init(_ first: RotatingKVCache) {
        window = first.maxSize ?? 0
        let (keys, values, position) = Self.inOrder(first)
        self.keys = keys
        self.values = values
        width = keys?.dim(2) ?? 0
        padding = [0]
        positions = [position]
    }

    private init(window: Int) {
        self.window = window
    }

    /// Whether a sequence's rotating cache can be batched: one that keeps no tokens at the start (`keep`).
    static func accepts(_ cache: RotatingKVCache) -> Bool {
        cache.metaState.first == "0" && cache.maxSize != nil
    }

    /// A rotating cache's keys and values oldest first, at most the window of them, and its token count.
    private static func inOrder(_ cache: RotatingKVCache) -> (MLXArray?, MLXArray?, Int) {
        let meta = cache.metaState
        let position = Int(meta[3]) ?? 0
        let next = Int(meta[4]) ?? 0
        let state = cache.state
        guard state.count == 2 else { return (nil, nil, position) }
        var (keys, values) = (state[0], state[1])
        let columns = keys.dim(2)
        if position > columns, next > 0, next < columns {
            // A full ring: the oldest column is the next one to be written.
            keys = concatenated([keys[.ellipsis, next..., 0...], keys[.ellipsis, ..<next, 0...]], axis: 2)
            values = concatenated([values[.ellipsis, next..., 0...], values[.ellipsis, ..<next, 0...]], axis: 2)
        }
        let window = cache.maxSize ?? columns
        if keys.dim(2) > window {
            keys = keys[.ellipsis, (keys.dim(2) - window)..., 0...]
            values = values[.ellipsis, (values.dim(2) - window)..., 0...]
        }
        return (keys, values, position)
    }

    var batchSize: Int {
        padding.count
    }

    // MARK: KVCache

    var offset: Int {
        width
    }

    var maxSize: Int? {
        nil
    }

    var ropeOffset: RoPEOffset {
        .batch(MLXArray(positions.map { Int32($0) }))
    }

    func innerState() -> [MLXArray] {
        [keys, values].compactMap(\.self)
    }

    func update(keys newKeys: MLXArray, values newValues: MLXArray) -> (MLXArray, MLXArray) {
        let previous = width
        let added = newKeys.dim(2)
        if keys == nil || previous + added > keys!.dim(2) {
            let columns = (previous + added + Self.step - 1) / Self.step * Self.step
            let grownKeys = MLXArray.zeros(
                [newKeys.dim(0), newKeys.dim(1), columns, newKeys.dim(3)],
                dtype: newKeys.dtype
            )
            let grownValues = MLXArray.zeros(
                [newValues.dim(0), newValues.dim(1), columns, newValues.dim(3)], dtype: newValues.dtype
            )
            if let keys, let values, previous > 0 {
                grownKeys[.ellipsis, ..<previous, 0...] = keys[.ellipsis, ..<previous, 0...]
                grownValues[.ellipsis, ..<previous, 0...] = values[.ellipsis, ..<previous, 0...]
            }
            keys = grownKeys
            values = grownValues
        }
        width += added
        positions = positions.map { $0 + added }
        keys![.ellipsis, previous ..< width, 0...] = newKeys
        values![.ellipsis, previous ..< width, 0...] = newValues
        let result = (keys![.ellipsis, ..<width, 0...], values![.ellipsis, ..<width, 0...])
        if width >= window + Self.step {
            trim(to: window)
        }
        return result
    }

    /// Keeps the last `count` columns, in a buffer of their own.
    private func trim(to count: Int) {
        guard let keys, let values, width > count else { return }
        let dropped = width - count
        self.keys = contiguous(keys[.ellipsis, dropped ..< width, 0...])
        self.values = contiguous(values[.ellipsis, dropped ..< width, 0...])
        padding = padding.map { max(0, $0 - dropped) }
        width = count
    }

    /// Causal and within the window, and nothing from a row's padding.
    func makeMask(n: Int, windowSize: Int?, returnArray: Bool) -> MLXFast.ScaledDotProductAttentionMaskMode {
        let span = windowSize ?? window
        let columns = MLXArray(Int32(0) ..< Int32(width + n)).expandedDimensions(axis: 0)
        let rows = MLXArray(Int32(width) ..< Int32(width + n)).expandedDimensions(axis: 1)
        var keep = (rows .>= columns) & (rows .< columns + MLXArray(Int32(span)))
        let padded = padding.contains { $0 > 0 }
        if padded {
            let starts = MLXArray(padding.map { Int32($0) }).expandedDimensions(axes: [1, 2, 3])
            keep = keep.expandedDimensions(axes: [0, 1]) & (columns.expandedDimensions(axes: [0, 1]) .>= starts)
        }
        if !padded, !returnArray, n == 1, width + n <= span {
            return .none
        }
        return .array(keep)
    }

    var state: [MLXArray] {
        get {
            guard let keys, let values else { return [] }
            return [keys[.ellipsis, ..<width, 0...], values[.ellipsis, ..<width, 0...]]
        }
        set {
            guard newValue.count == 2 else { return }
            keys = newValue[0]
            values = newValue[1]
            width = newValue[0].dim(2)
        }
    }

    var metaState: [String] {
        get { [""] }
        set {}
    }

    var isTrimmable: Bool {
        false
    }

    @discardableResult
    func trim(_: Int) -> Int {
        0
    }

    func copy() -> any KVCache {
        let new = BatchSlidingKVCache(window: window)
        new.keys = keys.map { $0[.ellipsis] }
        new.values = values.map { $0[.ellipsis] }
        new.padding = padding
        new.positions = positions
        new.width = width
        return new
    }

    // MARK: Joining and leaving

    /// Adds a prefilled sequence as the last row, padding whichever side is shorter.
    func extend(_ other: RotatingKVCache) {
        let (otherKeys, otherValues, position) = Self.inOrder(other)
        guard let otherKeys, let otherValues, let keys, let values else { return }
        let otherWidth = otherKeys.dim(2)
        let wide = max(width, otherWidth)
        var ownKeys = keys[.ellipsis, ..<width, 0...]
        var ownValues = values[.ellipsis, ..<width, 0...]
        if wide > width {
            ownKeys = Self.leftPad(ownKeys, by: wide - width)
            ownValues = Self.leftPad(ownValues, by: wide - width)
            padding = padding.map { $0 + wide - width }
        }
        self.keys = concatenated([ownKeys, Self.leftPad(otherKeys, by: wide - otherWidth)], axis: 0)
        self.values = concatenated([ownValues, Self.leftPad(otherValues, by: wide - otherWidth)], axis: 0)
        padding.append(wide - otherWidth)
        positions.append(position)
        width = wide
    }

    /// Keeps only the rows at `indices`, in that order, and drops padding every row now has.
    func filter(_ indices: [Int]) {
        padding = indices.map { padding[$0] }
        positions = indices.map { positions[$0] }
        let rows = MLXArray(indices.map { Int32($0) })
        keys = keys?[rows]
        values = values?[rows]
        if let shared = padding.min(), shared > 0 {
            keys = keys?[.ellipsis, shared..., 0...]
            values = values?[.ellipsis, shared..., 0...]
            padding = padding.map { $0 - shared }
            width -= shared
        }
    }

    /// Row `index`'s sequence as a rotating cache of its own, as the model makes them.
    func slice(_ index: Int) -> RotatingKVCache {
        let cache = RotatingKVCache(maxSize: window, keep: 0)
        guard let keys, let values, width > padding[index] else { return cache }
        let start = max(padding[index], width - window)
        let rows = index ..< index + 1, columns = start ..< width
        cache.state = [contiguous(keys[rows, 0..., columns, 0...]), contiguous(values[rows, 0..., columns, 0...])]
        cache.metaState = ["0", String(window), String(Self.step), String(positions[index]), String(width - start)]
        return cache
    }

    private static func leftPad(_ array: MLXArray, by count: Int) -> MLXArray {
        guard count > 0 else { return array }
        var shape = array.shape
        shape[2] = count
        return concatenated([MLXArray.zeros(shape, dtype: array.dtype), array], axis: 2)
    }
}

/// A model's per-layer caches for several sequences at once: `BatchKVCache` for attention layers,
/// `BatchSlidingKVCache` for sliding-window ones, and for a hybrid model's recurrent layers mlx-swift-lm's own
/// `MambaCache`, which already batches (`extend`, `filter`).
enum BatchedLayers {
    /// Whether a sequence's caches can join a batch: plain attention, sliding-window and recurrent caches only
    /// (not quantized or chunked ones).
    static func canBatch(_ layers: [any KVCache]) -> Bool {
        layers.allSatisfy { layer in
            if let rotating = layer as? RotatingKVCache {
                return type(of: layer) == RotatingKVCache.self && BatchSlidingKVCache.accepts(rotating)
            }
            return type(of: layer) == KVCacheSimple.self || type(of: layer) == MambaCache.self
        }
    }

    /// The first sequences' caches merged into one batch.
    static func merge(_ sequences: [[any KVCache]]) -> [any KVCache] {
        let batch: [any KVCache] = sequences[0].map { layer in
            if let simple = layer as? KVCacheSimple {
                return BatchKVCache(simple)
            }
            if let rotating = layer as? RotatingKVCache {
                return BatchSlidingKVCache(rotating)
            }
            return (layer as! MambaCache).copy()
        }
        for layers in sequences.dropFirst() {
            extend(batch, with: layers)
        }
        return batch
    }

    /// One more sequence as the last row.
    static func extend(_ batch: [any KVCache], with layers: [any KVCache]) {
        for (batched, layer) in zip(batch, layers) {
            if let batched = batched as? BatchKVCache {
                batched.extend(layer as! KVCacheSimple)
            } else if let batched = batched as? BatchSlidingKVCache {
                batched.extend(layer as! RotatingKVCache)
            } else {
                (batched as! MambaCache).extend(other: layer as! MambaCache)
            }
        }
    }

    static func filter(_ batch: [any KVCache], keeping indices: [Int]) {
        let rows = MLXArray(indices.map { Int32($0) })
        for batched in batch {
            if let batched = batched as? BatchKVCache {
                batched.filter(indices)
            } else if let batched = batched as? BatchSlidingKVCache {
                batched.filter(indices)
            } else {
                (batched as! MambaCache).filter(batchIndices: rows)
            }
        }
    }

    /// Row `index`'s caches, as the model's own cache types.
    static func slice(_ batch: [any KVCache], row index: Int) -> [any KVCache] {
        batch.map { batched in
            if let batched = batched as? BatchKVCache {
                return batched.slice(index)
            }
            if let batched = batched as? BatchSlidingKVCache {
                return batched.slice(index)
            }
            let own = batched.copy() as! MambaCache
            own.filter(batchIndices: MLXArray([Int32(index)]))
            return own
        }
    }

    /// Bytes one token takes in a sequence's attention caches (recurrent state doesn't grow with length).
    static func bytesPerToken(_ layers: [any KVCache]) -> Int {
        layers.compactMap { $0 as? KVCacheSimple }.reduce(0) { total, layer in
            guard layer.offset > 0 else { return total }
            return total + layer.state.reduce(0) { $0 + $1.nbytes } / layer.offset
        }
    }
}
