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

/// A model's per-layer caches for several sequences at once: `BatchKVCache` for attention layers, and for a
/// hybrid model's recurrent layers mlx-swift-lm's own `MambaCache`, which already batches (`extend`, `filter`).
enum BatchedLayers {
    /// Whether a sequence's caches can join a batch: plain attention caches and recurrent caches only (not
    /// sliding-window, quantized or chunked ones).
    static func canBatch(_ layers: [any KVCache]) -> Bool {
        layers.allSatisfy { type(of: $0) == KVCacheSimple.self || type(of: $0) == MambaCache.self }
    }

    /// The first sequences' caches merged into one batch.
    static func merge(_ sequences: [[any KVCache]]) -> [any KVCache] {
        let batch: [any KVCache] = sequences[0].map { layer in
            if let simple = layer as? KVCacheSimple {
                return BatchKVCache(simple)
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
