///
/// A note on the design of this binding: initially I built it with a
///  wrapper struct Bitmap that carried the *roaring_bitmap_t handle.
///  This fell apart however because we need to distinguish between const
///  and non-const bitmaps (e.g. frozen_view).  I could have used the
///  wrapper struct strictly in a pointer context but then we'd have
///  double-indirection purely for the sake of nice method style function
///  calling.
/// So here's what I did: I reimplement the roaring_bitmap_t type as
///  Bitmap (really easy, just a single member) and then do compile-time
///  @ptrCast calls (wrapped as from/to with const variants).

const c = @cImport({
    @cInclude("roaring.h");
});
const std = @import("std");

///
pub const RoaringError = error {
    ///
    allocation_failed,
    ///
    frozen_view_failed,
    ///
    deserialize_failed,
};

// Ensure 1:1 equivalence of roaring_bitmap_t and Bitmap
comptime {
    if (@sizeOf(Bitmap) != @sizeOf(c.roaring_bitmap_t)) {
        @compileError("Bitmap and roaring_bitmap_t are not the same size");
    }
}

/// This struct reimplements CRoaring's roaring_bitmap_t type
///  and can be @ptrCast to and from it.
/// (almost) all methods from the roaring_bitmap_t type should be available here.
pub const Bitmap = extern struct {
    high_low_container: c.roaring_array_t,

    //=========================== Type conversions ===========================//
    /// Performs conversions:
    ///  * *roaring_bitmap_t => *Bitmap
    ///  * *const roaring_bitmap_t => *const Bitmap
    ///  * *Bitmap => *roaring_bitmap_t
    ///  * *const Bitmap => *const roaring_bitmap_t
    /// This should be a pure type-system operation and not produce any
    ///  runtime instructions.
    /// You can use this function if you get a raw *roaring_bitmap_t from
    ///  somewhere and want to "convert" it into a *Bitmap. Or vice-versa.
    /// Important: this is simply casting the pointer, not producing any kind
    ///  of copy, make sure you own the memory and know what other pointers
    ///  to the same data are out there.
    pub fn conv(bitmap: anytype) convType(@TypeOf(bitmap)) {
        return @ptrCast(convType(@TypeOf(bitmap)), bitmap);
    }

    // Support function for conversion.  Given an input type, produces the
    //  appropriate target type.
    fn convType(comptime T: type) type {
        // We'll just grab the type info, swap out the child field and be done
        // This way const/non-const are handled automatically
        var info = @typeInfo(T);
        info.Pointer.child = switch (info.Pointer.child) {
            c.roaring_bitmap_t => Bitmap,
            Bitmap => c.roaring_bitmap_t,
            else => unreachable // don't call this with anything else
        };
        return @Type(info); // turn the modified TypeInfo into a type
    }


    //============================= Create/free =============================//

    // Helper function to ensure null bitmaps turn into errors
    fn checkNewBitmap(bitmap: ?*c.roaring_bitmap_t) RoaringError!*Bitmap {
        if (bitmap) |b| {
            return conv(b);
        } else {
            return RoaringError.allocation_failed;
        }
    }

    /// Dynamically allocates a new bitmap (initially empty).
    /// Returns an error if the allocation fails.
    /// Client is responsible for calling `free()`.
    pub fn create() RoaringError!*Bitmap {
        return checkNewBitmap( c.roaring_bitmap_create() );
    }

    /// Dynamically allocates a new bitmap (initially empty).
    /// Returns an error if the allocation fails.
    /// Capacity is a performance hint for how many "containers" the data will need.
    /// Client is responsible for calling `free()`.
    pub fn createWithCapacity(capacity: u32) RoaringError!*Bitmap {
        return checkNewBitmap( c.roaring_bitmap_create_with_capacity(capacity) );
    }

    ///
    pub fn free(self: *Bitmap) void {
        c.roaring_bitmap_free(conv(self));
    }

    ///
    pub fn fromRange(min: u64, max: u64, step: u32) RoaringError!*Bitmap {
        return checkNewBitmap( c.roaring_bitmap_from_range(min, max, step) );
    }

    ///
    pub fn fromSlice(vals: []u32) RoaringError!*Bitmap {
        return checkNewBitmap( c.roaring_bitmap_of_ptr(vals.len, vals.ptr) );
    }

    ///
    pub fn getCopyOnWrite(self: *const Bitmap) bool {
        return c.roaring_bitmap_get_copy_on_write(conv(self));
    }

    /// Whether you want to use copy-on-write.
    /// Saves memory and avoids copies, but needs more care in a threaded context.
    /// Most users should ignore this flag.
    ///
    /// Note: If you do turn this flag to 'true', enabling COW, then ensure that you
    /// do so for all of your bitmaps, since interactions between bitmaps with and
    /// without COW is unsafe.
    pub fn setCopyOnWrite(self: *Bitmap, value: bool) void {
        c.roaring_bitmap_set_copy_on_write(conv(self), value);
    }

    /// Copies a bitmap (this does memory allocation).
    /// The caller is responsible for memory management.
    pub fn copy(self: *const Bitmap) RoaringError!*Bitmap {
        return checkNewBitmap( c.roaring_bitmap_copy(conv(self)) );
    }

    /// Copies a bitmap from src to dest. It is assumed that the pointer dest
    /// is to an already allocated bitmap. The content of the dest bitmap is
    /// freed/deleted.
    ///
    /// It might be preferable and simpler to call roaring_bitmap_copy except
    /// that roaring_bitmap_overwrite can save on memory allocations.
    pub fn overwrite(dest: *Bitmap, src: *const Bitmap) bool {
        return c.roaring_bitmap_overwrite(conv(dest), conv(src));
    }


    //=========================== Add/remove/test ===========================//
    ///
    pub fn add(self: *Bitmap, x: u32) void {
        c.roaring_bitmap_add(conv(self), x);
    }

    ///
    pub fn addMany(self: *Bitmap, vals: []u32) void {
        c.roaring_bitmap_add_many(conv(self), vals.len, vals.ptr);
    }

    /// Add value x
    /// Returns true if a new value was added, false if the value already existed.
    pub fn addChecked(self: *Bitmap, x: u32) bool {
        return c.roaring_bitmap_add_checked(conv(self), x);
    }

    /// Add all values in range [min, max]
    pub fn addRangeClosed(self: *Bitmap, start: u32, end: u32) void {
        c.roaring_bitmap_add_range_closed(conv(self), start, end);
    }

    /// Add all values in range [min, max)
    pub fn addRange(self: *Bitmap, start: u64, end: u64) void {
        c.roaring_bitmap_add_range(conv(self), start, end);
    }

    ///
    pub fn remove(self: *Bitmap, x: u32) void {
        c.roaring_bitmap_remove(conv(self), x);
    }

    /// Remove value x
    /// Returns true if a new value was removed, false if the value was not existing.
    pub fn removeChecked(self: *Bitmap, x: u32) bool {
        return c.roaring_bitmap_remove_checked(conv(self), x);
    }

    /// Remove multiple values
    pub fn removeMany(self: *Bitmap, vals: []u32) void {
        c.roaring_bitmap_remove_many(conv(self), vals.len, vals.ptr);
    }

    /// Remove all values in range [min, max)
    pub fn removeRange(self: *Bitmap, min: u64, max: u64) void {
        c.roaring_bitmap_remove_range(conv(self), min, max);
    }

    /// Remove all values in range [min, max]
    pub fn removeRangeClosed(self: *Bitmap, min: u32, max: u32) void {
        c.roaring_bitmap_remove_range_closed(conv(self), min, max);
    }

    ///
    pub fn clear(self: *Bitmap) void {
        c.roaring_bitmap_clear(conv(self));
    }

    ///
    pub fn contains(self: *const Bitmap, x: u32) bool {
        return c.roaring_bitmap_contains(conv(self), x);
    }

    /// Check whether a range of values from range_start (included)
    ///  to range_end (excluded) is present
    pub fn containsRange(self: *const Bitmap, start: u64, end: u64) bool {
        return c.roaring_bitmap_contains_range(conv(self), start, end);
    }

    ///
    pub fn empty(self: *const Bitmap) bool {
        return c.roaring_bitmap_is_empty(conv(self));
    }


    //========================== Bitwise operations ==========================//
    ///
    pub fn _and(a: *const Bitmap, b: *const Bitmap) RoaringError!*Bitmap {
        return checkNewBitmap( c.roaring_bitmap_and(conv(a), conv(b)) );
    }

    ///
    pub fn _andInPlace(a: *Bitmap, b: *const Bitmap) void {
        c.roaring_bitmap_and_inplace(conv(a), conv(b));
    }

    ///
    pub fn _andCardinality(a: *const Bitmap, b: *const Bitmap) u64 {
        return c.roaring_bitmap_and_cardinality(conv(a), conv(b));
    }

    ///
    pub fn intersect(a: *const Bitmap, b: *const Bitmap) bool {
        return c.roaring_bitmap_intersect(conv(a), conv(b));
    }

    ///
    pub fn jaccardIndex(a: *const Bitmap, b: *const Bitmap) f64 {
        return c.roaring_bitmap_jaccard_index(conv(a), conv(b));
    }

    ///
    pub fn _or(a: *const Bitmap, b: *const Bitmap) RoaringError!*Bitmap {
        return checkNewBitmap( c.roaring_bitmap_or(conv(a), conv(b)) );
    }

    ///
    pub fn _orInPlace(a: *Bitmap, b: *const Bitmap) void {
        c.roaring_bitmap_or_inplace(conv(a), conv(b));
    }

    ///
    pub fn _orMany(bitmaps: []*const Bitmap) RoaringError!*Bitmap {
        return checkNewBitmap( c.roaring_bitmap_or_many(
                    @intCast(u32, bitmaps.len),
                    @ptrCast([*c][*c]const c.roaring_bitmap_t, bitmaps.ptr)
        ) );
    }

    ///
    pub fn _orManyHeap(bitmaps: []*const Bitmap) RoaringError!*Bitmap {
        return checkNewBitmap( c.roaring_bitmap_or_many_heap(
                    @intCast(u32, bitmaps.len),
                    @ptrCast([*c][*c]const c.roaring_bitmap_t, bitmaps.ptr)
        ) );
    }

    ///
    pub fn _orCardinality(a: *const Bitmap, b: *const Bitmap) usize {
        return c.roaring_bitmap_or_cardinality(conv(a), conv(b));
    }


    ///
    pub fn _xor(a: *const Bitmap, b: *const Bitmap) RoaringError!*Bitmap {
        return checkNewBitmap( c.roaring_bitmap_xor(conv(a), conv(b)) );
    }

    ///
    pub fn _xorInPlace(a: *Bitmap, b: *const Bitmap) void {
        c.roaring_bitmap_xor_inplace(conv(a), conv(b));
    }

    ///
    pub fn _xorCardinality(a: *const Bitmap, b: *const Bitmap) usize {
        return c.roaring_bitmap_xor_cardinality(conv(a), conv(b));
    }

    ///
    pub fn _xorMany(bitmaps: []*const Bitmap) RoaringError!*Bitmap {
        return checkNewBitmap(c.roaring_bitmap_xor_many(
                    @intCast(u32, bitmaps.len),
                    @ptrCast([*c][*c]const c.roaring_bitmap_t, bitmaps.ptr)
        ));
    }

    ///
    pub fn _andnot(a: *const Bitmap, b: *const Bitmap) RoaringError!*Bitmap {
        return checkNewBitmap(c.roaring_bitmap_andnot(conv(a), conv(b)));
    }

    ///
    pub fn _andnotInPlace(a: *Bitmap, b: *const Bitmap) void {
        c.roaring_bitmap_andnot_inplace(conv(a), conv(b));
    }

    ///
    pub fn _andnotCardinality(a: *const Bitmap, b: *const Bitmap) usize {
        return c.roaring_bitmap_andnot_cardinality(conv(a), conv(b));
    }

    ///
    pub fn flip(self: *const Bitmap, start: u64, end: u64) RoaringError!*Bitmap {
        return checkNewBitmap(c.roaring_bitmap_flip(conv(self), start, end));
    }

    ///
    pub fn flipInPlace(self: *Bitmap, start: u64, end: u64) void {
        c.roaring_bitmap_flip_inplace(conv(self), start, end);
    }


    //======================= Lazy bitwise operations =======================//
    /// (For expert users who seek high performance.)
    ///
    /// Computes the union between two bitmaps and returns new bitmap. The caller is
    /// responsible for memory management.
    ///
    /// The lazy version defers some computations such as the maintenance of the
    /// cardinality counts. Thus you must call `roaring_bitmap_repair_after_lazy()`
    /// after executing "lazy" computations.
    ///
    /// It is safe to repeatedly call roaring_bitmap_lazy_or_inplace on the result.
    ///
    /// `bitsetconversion` is a flag which determines whether container-container
    /// operations force a bitset conversion.
    pub fn _orLazy(a: *const Bitmap, b: *const Bitmap, convert: bool) RoaringError!*Bitmap {
        return checkNewBitmap(c.roaring_bitmap_lazy_or(conv(a), conv(b), convert));
    }

    /// (For expert users who seek high performance.)
    ///
    /// Inplace version of roaring_bitmap_lazy_or, modifies r1.
    ///
    /// `bitsetconversion` is a flag which determines whether container-container
    /// operations force a bitset conversion.
    pub fn _orLazyInPlace(a: *Bitmap, b: *const Bitmap, convert: bool) void {
        c.roaring_bitmap_lazy_or_inplace(conv(a), conv(b), convert);
    }

    /// Computes the symmetric difference between two bitmaps and returns new bitmap.
    /// The caller is responsible for memory management.
    ///
    /// The lazy version defers some computations such as the maintenance of the
    /// cardinality counts. Thus you must call `roaring_bitmap_repair_after_lazy()`
    /// after executing "lazy" computations.
    ///
    /// It is safe to repeatedly call `roaring_bitmap_lazy_xor_inplace()` on
    /// the result.
    pub fn _xorLazy(a: *const Bitmap, b: *const Bitmap) RoaringError!*Bitmap {
        return checkNewBitmap(c.roaring_bitmap_lazy_xor(conv(a), conv(b)));
    }

    /// (For expert users who seek high performance.)
    ///
    /// Inplace version of roaring_bitmap_lazy_xor, modifies r1. r1 != r2
    pub fn _xorLazyInPlace(a: *Bitmap, b: *const Bitmap) void {
        c.roaring_bitmap_lazy_xor_inplace(conv(a), conv(b));
    }

    /// (For expert users who seek high performance.)
    ///
    /// Execute maintenance on a bitmap created from `roaring_bitmap_lazy_or()`
    /// or modified with `roaring_bitmap_lazy_or_inplace()`.
    pub fn repairAfterLazy(a: *Bitmap) void {
        c.roaring_bitmap_repair_after_lazy(conv(a));
    }


    //============================ Serialization ============================//
    ///
    pub fn serialize(self: *const Bitmap, buf: []u8) usize {
        return c.roaring_bitmap_serialize(conv(self), buf.ptr);
    }

    ///
    pub fn deserialize(buf: []const u8) RoaringError!*Bitmap {
        return checkNewBitmap(c.roaring_bitmap_deserialize(buf.ptr));
    }

    ///
    pub fn sizeInBytes(self: *const Bitmap) usize {
        return c.roaring_bitmap_size_in_bytes(conv(self));
    }

    ///
    pub fn portableSerialize(self: *const Bitmap, buf: []u8) usize {
        return c.roaring_bitmap_portable_serialize(conv(self), buf.ptr);
    }

    ///
    pub fn portableDeserialize(buf: []const u8) RoaringError!*Bitmap {
        return checkNewBitmap(c.roaring_bitmap_portable_deserialize(buf.ptr));
    }

    ///
    pub fn portableDeserializeSafe(buf: []const u8) RoaringError! *Bitmap {
        if (c.roaring_bitmap_portable_deserialize_safe(buf.ptr, buf.len)) |b| {
            return conv(b);
        } else {
            return RoaringError.deserialize_failed;
        }
    }

    ///
    pub fn portableDeserializeSize(buf: []const u8) usize {
        return c.roaring_bitmap_portable_deserialize_size(buf.ptr, buf.len);
    }

    ///
    pub fn portableSizeInBytes(self: *const Bitmap) usize {
        return c.roaring_bitmap_portable_size_in_bytes(conv(self));
    }


    //========================= Frozen functionality =========================//
    ///
    pub fn frozenSizeInBytes(self: *const Bitmap) usize {
        return c.roaring_bitmap_frozen_size_in_bytes(conv(self));
    }

    ///
    pub fn frozenSerialize(self: *const Bitmap, buf: []u8) void {
        c.roaring_bitmap_frozen_serialize(conv(self), buf.ptr);
    }

    /// Returns a read-only Bitmap, backed by the bytes in `buf`.  You must not
    ///  free or alter the bytes in `buf` while the view bitmap is alive.
    /// `buf` must be 32-byte aligned and exactly the length that was reported
    ///  by `frozenSizeInBytes`.
    pub fn frozenView(buf: []align(32)u8) RoaringError ! *const Bitmap {
        return conv( c.roaring_bitmap_frozen_view(buf.ptr, buf.len)
                     orelse return RoaringError.frozen_view_failed );
    }

    //============================== Comparison ==============================//
    ///
    pub fn eql(a: *const Bitmap, b: *const Bitmap) bool {
        return c.roaring_bitmap_equals(conv(a), conv(b));
    }

    /// Return true if all the elements of r1 are also in r2.
    pub fn isSubset(a: *const Bitmap, b: *const Bitmap) bool {
        return c.roaring_bitmap_is_subset(conv(a), conv(b));
    }

    /// Return true if all the elements of r1 are also in r2, and r2 is strictly
    ///  greater than r1.
    pub fn isStrictSubset(a: *const Bitmap, b: *const Bitmap) bool {
        return c.roaring_bitmap_is_strict_subset(conv(a), conv(b));
    }


    //============================ Miscellaneous ============================//
    ///
    pub fn cardinality(self: *const Bitmap) u64 {
        return c.roaring_bitmap_get_cardinality(conv(self));
    }

    /// Returns the number of elements in the range [range_start, range_end).
    pub fn cardinalityRange(self: *const Bitmap, start: u64, end: u64) u64 {
        return c.roaring_bitmap_range_cardinality(conv(self), start, end);
    }

    ///
    pub fn minimum(self: *const Bitmap) u32 {
        return c.roaring_bitmap_minimum(conv(self));
    }

    ///
    pub fn maximum(self: *const Bitmap) u32 {
        return c.roaring_bitmap_maximum(conv(self));
    }

    /// Selects the element at index 'rank' where the smallest element is at index 0.
    /// If the size of the roaring bitmap is strictly greater than rank, then this
    /// function returns true and sets element to the element of given rank.
    /// Otherwise, it returns false.
    pub fn select(self: *const Bitmap, rnk: u32, element: *u32) bool {
        return c.roaring_bitmap_select(conv(self), rnk, element);
    }

    /// Returns the number of integers that are smaller or equal to x.
    /// Thus if x is the first element, this function will return 1. If
    /// x is smaller than the smallest element, this function will return 0.
    ///
    /// The indexing convention differs between `select` and `rank`:
    ///  `select` refers to the smallest value as having index 0, whereas `rank`
    ///   returns 1 when ranking the smallest value.
    pub fn rank(self: *const Bitmap, x: u32) u64 {
        return c.roaring_bitmap_rank(conv(self), x);
    }

    /// Describe the inner structure of the bitmap.
    pub fn printfDescribe(self: *const Bitmap) void {
        c.roaring_bitmap_printf_describe(conv(self));
    }

    ///
    pub fn printf(self: *const Bitmap) void {
        c.roaring_bitmap_printf(conv(self));
    }


    //============================= Optimization =============================//
    /// Remove run-length encoding even when it is more space efficient.
    /// Return whether a change was applied.
    pub fn removeRunCompression(self: *Bitmap) bool {
        return c.roaring_bitmap_remove_run_compression(conv(self));
    }

    /// Convert array and bitmap containers to run containers when it is more
    /// efficient; also convert from run containers when more space efficient.
    ///
    /// Returns true if the result has at least one run container.
    /// Additional savings might be possible by calling `shrinkToFit()`.
    pub fn runOptimize(self: *Bitmap) bool {
        return c.roaring_bitmap_run_optimize(conv(self));
    }

    /// If needed, reallocate memory to shrink the memory usage.
    /// Returns the number of bytes saved.
    pub fn shrinkToFit(self: *Bitmap) usize {
        return c.roaring_bitmap_shrink_to_fit(conv(self));
    }


    //============================== Iteration ==============================//
    ///
    const Iterator = struct {
        i: c.roaring_uint32_iterator_t,

        ///
        pub fn hasValue(self: Iterator) bool {
            return self.i.has_value;
        }

        ///
        pub fn currentValue(self: Iterator) u32 {
            return self.i.current_value;
        }

        ///
        pub fn next(self: *Iterator) bool {
            return c.roaring_advance_uint32_iterator(&self.i);
        }

        ///
        pub fn previous(self: *Iterator) bool {
            return c.roaring_previous_uint32_iterator(&self.i);
        }

        ///
        pub fn moveEqualOrLarger(self: *Iterator, x: u32) bool {
            return c.roaring_move_uint32_iterator_equalorlarger(&self.i, x);
        }

        ///
        pub fn read(self: *Iterator, buf: []u32) u32 {
            return c.roaring_read_uint32_iterator(&self.i,
                                                buf.ptr, @intCast(u32, buf.len));
        }
    };

    ///
    pub fn iterator(self: *const Bitmap) Iterator {
        var ret: Iterator = undefined;
        c.roaring_init_iterator(conv(self), &ret.i);
        return ret;
    }
};

/// Helper function to get properly aligned and sized buffers for
///  frozenSerialize/frozenView
pub fn allocForFrozen(allocator: std.mem.Allocator, len: usize) ![]align(32)u8 {
    // The buffer must be 32-byte aligned and sized exactly
    return allocator.allocAdvanced(u8,
        32, // alignment
        len,
        std.mem.Allocator.Exact.exact
    );
}
