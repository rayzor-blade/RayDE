/**
 * How a run ended, as a page sees it.
 */
export class Outcome {
    static __wrap(ptr) {
        const obj = Object.create(Outcome.prototype);
        obj.__wbg_ptr = ptr;
        OutcomeFinalization.register(obj, obj.__wbg_ptr, obj);
        return obj;
    }
    __destroy_into_raw() {
        const ptr = this.__wbg_ptr;
        this.__wbg_ptr = 0;
        OutcomeFinalization.unregister(this);
        return ptr;
    }
    free() {
        const ptr = this.__destroy_into_raw();
        wasm.__wbg_outcome_free(ptr, 0);
    }
    /**
     * What the program exited with.
     * @returns {number}
     */
    get status() {
        const ret = wasm.outcome_status(this.__wbg_ptr);
        return ret;
    }
    /**
     * The trap, if it ended in one. A program that called `Sys.exit` did
     * not, however it looked from inside: `proc_exit` unwinds by throwing,
     * which is how a wasm program leaves a stack it cannot return through.
     * @returns {string | undefined}
     */
    get trapped() {
        const ret = wasm.outcome_trapped(this.__wbg_ptr);
        let v1;
        if (ret[0] !== 0) {
            v1 = getStringFromWasm0(ret[0], ret[1]);
            wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        }
        return v1;
    }
}
if (Symbol.dispose) Outcome.prototype[Symbol.dispose] = Outcome.prototype.free;

/**
 * Prepare a native library as soon as its bytes are in; see
 * [`prepare_program`]. `threads` asks for the module a thread's instance is
 * made from as well, which a program that uses threads needs.
 * @param {Uint8Array} bytes
 * @param {boolean} threads
 * @returns {object}
 */
export function prepare_library(bytes, threads) {
    const ret = wasm.prepare_library(bytes, threads);
    if (ret[2]) {
        throw takeFromExternrefTable0(ret[1]);
    }
    return takeFromExternrefTable0(ret[0]);
}

/**
 * Rewrite and compile a program as soon as its bytes are in, so that the
 * work overlaps whatever else the page is still downloading. Hand the result
 * to [`run`] in place of the bytes.
 * @param {Uint8Array} module
 * @returns {object}
 */
export function prepare_program(module) {
    const ret = wasm.prepare_program(module);
    if (ret[2]) {
        throw takeFromExternrefTable0(ret[1]);
    }
    return takeFromExternrefTable0(ret[0]);
}

/**
 * Run a module, and answer how it ended.
 *
 * `module` is the program's bytes, or what [`prepare_program`] made of them.
 * `args` is `Sys.args()`, argv[0] included; `environ` is
 * `Sys.environment()`, each entry already `NAME=value`. `libraries`, when
 * given, maps each native library's name to its side module's bytes, or to
 * what [`prepare_library`] made of them; they are loaded before the program
 * runs (see [`super::dylink`]).
 * @param {any} module
 * @param {string[]} args
 * @param {string[]} environ
 * @param {Function | null} [spawn]
 * @param {object | null} [libraries]
 * @returns {Promise<Outcome>}
 */
export function run(module, args, environ, spawn, libraries) {
    const ptr0 = passArrayJsValueToWasm0(args, wasm.__wbindgen_malloc);
    const len0 = WASM_VECTOR_LEN;
    const ptr1 = passArrayJsValueToWasm0(environ, wasm.__wbindgen_malloc);
    const len1 = WASM_VECTOR_LEN;
    const ret = wasm.run(module, ptr0, len0, ptr1, len1, isLikeNone(spawn) ? 0 : addToExternrefTable0(spawn), isLikeNone(libraries) ? 0 : addToExternrefTable0(libraries));
    return ret;
}

/**
 * Run one thread: the same module, the same memory, entered where wasi-libc
 * leaves off.
 *
 * This is what the Worker a page started in `spawn` calls. It instantiates
 * rather than fetches, because the module arrives already compiled, and it
 * calls `wasi_thread_start` rather than an entrypoint -- the guest's own
 * `pthread_create` prepared `start_arg`, and everything about what this
 * thread will do is in there.
 * @param {WebAssembly.Module} module
 * @param {WebAssembly.Memory} memory
 * @param {number} tid
 * @param {number} start_arg
 * @param {string[]} args
 * @param {string[]} environ
 * @param {Function | null | undefined} spawn
 * @param {SharedArrayBuffer | null | undefined} control
 * @param {any} libraries
 * @returns {Promise<void>}
 */
export function run_thread(module, memory, tid, start_arg, args, environ, spawn, control, libraries) {
    const ptr0 = passArrayJsValueToWasm0(args, wasm.__wbindgen_malloc);
    const len0 = WASM_VECTOR_LEN;
    const ptr1 = passArrayJsValueToWasm0(environ, wasm.__wbindgen_malloc);
    const len1 = WASM_VECTOR_LEN;
    const ret = wasm.run_thread(module, memory, tid, start_arg, ptr0, len0, ptr1, len1, isLikeNone(spawn) ? 0 : addToExternrefTable0(spawn), isLikeNone(control) ? 0 : addToExternrefTable0(control), libraries);
    return ret;
}
function __wbg_get_imports() {
    const import0 = {
        __proto__: null,
        __wbg___wbindgen_boolean_get_c9c83ebd41b34df3: function(arg0) {
            const v = arg0;
            const ret = typeof(v) === 'boolean' ? v : undefined;
            return isLikeNone(ret) ? 0xFFFFFF : ret ? 1 : 0;
        },
        __wbg___wbindgen_debug_string_a57024b9c6e4a48b: function(arg0, arg1) {
            const ret = debugString(arg1);
            const ptr1 = passStringToWasm0(ret, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
            const len1 = WASM_VECTOR_LEN;
            getDataViewMemory0().setInt32(arg0 + 4 * 1, len1, true);
            getDataViewMemory0().setInt32(arg0 + 4 * 0, ptr1, true);
        },
        __wbg___wbindgen_is_falsy_b7464e97ddc1b7a4: function(arg0) {
            const ret = !arg0;
            return ret;
        },
        __wbg___wbindgen_is_function_5e4570eb24ffa122: function(arg0) {
            const ret = typeof(arg0) === 'function';
            return ret;
        },
        __wbg___wbindgen_is_object_a2790eb24c211ea0: function(arg0) {
            const val = arg0;
            const ret = typeof(val) === 'object' && val !== null;
            return ret;
        },
        __wbg___wbindgen_is_undefined_6cff064c44e0d823: function(arg0) {
            const ret = arg0 === undefined;
            return ret;
        },
        __wbg___wbindgen_number_get_136b9679cab35cfb: function(arg0, arg1) {
            const obj = arg1;
            const ret = typeof(obj) === 'number' ? obj : undefined;
            getDataViewMemory0().setFloat64(arg0 + 8 * 1, isLikeNone(ret) ? 0 : ret, true);
            getDataViewMemory0().setInt32(arg0 + 4 * 0, !isLikeNone(ret), true);
        },
        __wbg___wbindgen_string_get_d154f1e671052120: function(arg0, arg1) {
            const obj = arg1;
            const ret = typeof(obj) === 'string' ? obj : undefined;
            var ptr1 = isLikeNone(ret) ? 0 : passStringToWasm0(ret, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
            var len1 = WASM_VECTOR_LEN;
            getDataViewMemory0().setInt32(arg0 + 4 * 1, len1, true);
            getDataViewMemory0().setInt32(arg0 + 4 * 0, ptr1, true);
        },
        __wbg___wbindgen_throw_bb96b2010945f0bc: function(arg0, arg1) {
            throw new Error(getStringFromWasm0(arg0, arg1));
        },
        __wbg__wbg_cb_unref_be22cc64ae6946a0: function(arg0) {
            arg0._wbg_cb_unref();
        },
        __wbg_buffer_8117fe4dab119813: function(arg0) {
            const ret = arg0.buffer;
            return ret;
        },
        __wbg_buffer_88205010cefc84de: function(arg0) {
            const ret = arg0.buffer;
            return ret;
        },
        __wbg_call_0f2a9af232c18fd2: function() { return handleError(function (arg0, arg1, arg2, arg3) {
            const ret = arg0.call(arg1, arg2, arg3);
            return ret;
        }, arguments); },
        __wbg_call_1c5886ab9c57d1c7: function() { return handleError(function (arg0, arg1) {
            const ret = arg0.call(arg1);
            return ret;
        }, arguments); },
        __wbg_call_35dba3c747ad7521: function() { return handleError(function (arg0, arg1, arg2) {
            const ret = arg0.call(arg1, arg2);
            return ret;
        }, arguments); },
        __wbg_close_b857478a8d4c1a16: function() { return handleError(function (arg0) {
            arg0.close();
        }, arguments); },
        __wbg_compareExchange_099530689324510a: function() { return handleError(function (arg0, arg1, arg2, arg3) {
            const ret = Atomics.compareExchange(arg0, arg1 >>> 0, arg2, arg3);
            return ret;
        }, arguments); },
        __wbg_data_57d8ce4eb5f0a433: function(arg0) {
            const ret = arg0.data;
            return ret;
        },
        __wbg_error_dd408a7b3cb542dd: function(arg0) {
            console.error(arg0);
        },
        __wbg_exports_7d05caa1a0c36b86: function(arg0) {
            const ret = arg0.exports;
            return ret;
        },
        __wbg_getRandomValues_6a55335db8979694: function() { return handleError(function (arg0, arg1, arg2) {
            const ret = arg0.getRandomValues(getArrayU8FromWasm0(arg1, arg2));
            return ret;
        }, arguments); },
        __wbg_get_01667a0edd483167: function() { return handleError(function (arg0, arg1) {
            const ret = Reflect.get(arg0, arg1 >>> 0);
            return ret;
        }, arguments); },
        __wbg_get_971a0c45d172643f: function() { return handleError(function (arg0, arg1) {
            const ret = Reflect.get(arg0, arg1);
            return ret;
        }, arguments); },
        __wbg_get_unchecked_e20b893aeafc3fca: function(arg0, arg1) {
            const ret = arg0[arg1 >>> 0];
            return ret;
        },
        __wbg_grow_adf1e32e3f3bb932: function() { return handleError(function (arg0, arg1) {
            const ret = arg0.grow(arg1 >>> 0);
            return ret;
        }, arguments); },
        __wbg_imports_d64558b2dafe33b8: function(arg0) {
            const ret = WebAssembly.Module.imports(arg0);
            return ret;
        },
        __wbg_instanceof_ArrayBuffer_993d02d2d254cad1: function(arg0) {
            let result;
            try {
                result = arg0 instanceof ArrayBuffer;
            } catch (_) {
                result = false;
            }
            const ret = result;
            return ret;
        },
        __wbg_instanceof_Crypto_812678122e872685: function(arg0) {
            let result;
            try {
                result = arg0 instanceof Crypto;
            } catch (_) {
                result = false;
            }
            const ret = result;
            return ret;
        },
        __wbg_instanceof_Global_eb9f44c43679a9c6: function(arg0) {
            let result;
            try {
                result = arg0 instanceof WebAssembly.Global;
            } catch (_) {
                result = false;
            }
            const ret = result;
            return ret;
        },
        __wbg_instanceof_Module_ce04f74c3d5a951e: function(arg0) {
            let result;
            try {
                result = arg0 instanceof WebAssembly.Module;
            } catch (_) {
                result = false;
            }
            const ret = result;
            return ret;
        },
        __wbg_instanceof_Performance_8338dc22fb86fd22: function(arg0) {
            let result;
            try {
                result = arg0 instanceof Performance;
            } catch (_) {
                result = false;
            }
            const ret = result;
            return ret;
        },
        __wbg_instanceof_SharedArrayBuffer_c734e76df6d827cb: function(arg0) {
            let result;
            try {
                result = arg0 instanceof SharedArrayBuffer;
            } catch (_) {
                result = false;
            }
            const ret = result;
            return ret;
        },
        __wbg_instanceof_Table_01ff4017eccbeab8: function(arg0) {
            let result;
            try {
                result = arg0 instanceof WebAssembly.Table;
            } catch (_) {
                result = false;
            }
            const ret = result;
            return ret;
        },
        __wbg_instanceof_Uint8Array_f935dbb0aa7cdeed: function(arg0) {
            let result;
            try {
                result = arg0 instanceof Uint8Array;
            } catch (_) {
                result = false;
            }
            const ret = result;
            return ret;
        },
        __wbg_instantiate_000d8f32d698c76f: function(arg0, arg1) {
            const ret = WebAssembly.instantiate(arg0, arg1);
            return ret;
        },
        __wbg_isArray_6339f732981044bf: function(arg0) {
            const ret = Array.isArray(arg0);
            return ret;
        },
        __wbg_keys_ec7f8c0c2370d91d: function(arg0) {
            const ret = Object.keys(arg0);
            return ret;
        },
        __wbg_length_1368b9bb66f6a6aa: function(arg0) {
            const ret = arg0.length;
            return ret;
        },
        __wbg_length_36bd29c6848c2144: function(arg0) {
            const ret = arg0.length;
            return ret;
        },
        __wbg_length_ecfa2c63d3d0d82c: function(arg0) {
            const ret = arg0.length;
            return ret;
        },
        __wbg_load_c7c58f19755d1352: function() { return handleError(function (arg0, arg1) {
            const ret = Atomics.load(arg0, arg1 >>> 0);
            return ret;
        }, arguments); },
        __wbg_log_e6372b4fbfc9f81e: function(arg0) {
            console.log(arg0);
        },
        __wbg_new_116be93542d39019: function() {
            const ret = new Array();
            return ret;
        },
        __wbg_new_20a7c62e9b30cbf7: function() { return handleError(function (arg0, arg1) {
            const ret = new WebSocket(getStringFromWasm0(arg0, arg1));
            return ret;
        }, arguments); },
        __wbg_new_3867db84790e6cb4: function(arg0) {
            const ret = new SharedArrayBuffer(arg0 >>> 0);
            return ret;
        },
        __wbg_new_77cc4f4f472aeb81: function(arg0) {
            const ret = new Uint8Array(arg0);
            return ret;
        },
        __wbg_new_90fdef5c10230223: function(arg0) {
            const ret = new BigInt64Array(arg0);
            return ret;
        },
        __wbg_new_bd7a161a1b96dc2a: function() { return handleError(function (arg0, arg1) {
            const ret = new WebAssembly.Global(arg0, arg1);
            return ret;
        }, arguments); },
        __wbg_new_d1599c9e69d35606: function() { return handleError(function (arg0, arg1) {
            const ret = new WebAssembly.Instance(arg0, arg1);
            return ret;
        }, arguments); },
        __wbg_new_e3fb27841b78e4f4: function() { return handleError(function (arg0) {
            const ret = new WebAssembly.Module(arg0);
            return ret;
        }, arguments); },
        __wbg_new_ebe3e0f6837f0879: function() {
            const ret = new Object();
            return ret;
        },
        __wbg_new_f545e2e1ea609f29: function(arg0) {
            const ret = new Int32Array(arg0);
            return ret;
        },
        __wbg_new_fee1181bcca662c4: function() { return handleError(function (arg0) {
            const ret = new WebAssembly.Memory(arg0);
            return ret;
        }, arguments); },
        __wbg_new_from_slice_3eea173078478cfe: function(arg0, arg1) {
            const ret = new Uint8Array(getArrayU8FromWasm0(arg0, arg1));
            return ret;
        },
        __wbg_new_typed_cceaf62d8d95e9f2: function(arg0, arg1) {
            try {
                var state0 = {a: arg0, b: arg1};
                var cb0 = (arg0, arg1) => {
                    const a = state0.a;
                    state0.a = 0;
                    try {
                        return wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___js_sys_9b95b060f9ea9f45___Function_fn_wasm_bindgen_5257fc0973cf488f___JsValue_____wasm_bindgen_5257fc0973cf488f___sys__Undefined___js_sys_9b95b060f9ea9f45___Function_fn_wasm_bindgen_5257fc0973cf488f___JsValue_____wasm_bindgen_5257fc0973cf488f___sys__Undefined_______true_(a, state0.b, arg0, arg1);
                    } finally {
                        state0.a = a;
                    }
                };
                const ret = new Promise(cb0);
                return ret;
            } finally {
                state0.a = 0;
            }
        },
        __wbg_new_with_byte_offset_and_length_ff6e927f8d72f0c3: function(arg0, arg1, arg2) {
            const ret = new Uint8Array(arg0, arg1 >>> 0, arg2 >>> 0);
            return ret;
        },
        __wbg_notify_5f5e34143c548cc7: function() { return handleError(function (arg0, arg1) {
            const ret = Atomics.notify(arg0, arg1 >>> 0);
            return ret;
        }, arguments); },
        __wbg_now_2283802bfbda617e: function(arg0) {
            const ret = arg0.now();
            return ret;
        },
        __wbg_now_8b265300afd5f2b9: function() {
            const ret = Date.now();
            return ret;
        },
        __wbg_outcome_new: function(arg0) {
            const ret = Outcome.__wrap(arg0);
            return ret;
        },
        __wbg_prototypesetcall_de8e0d9553586985: function(arg0, arg1, arg2) {
            Uint8Array.prototype.set.call(getArrayU8FromWasm0(arg0, arg1), arg2);
        },
        __wbg_push_adb0107829f02d75: function(arg0, arg1) {
            const ret = arg0.push(arg1);
            return ret;
        },
        __wbg_queueMicrotask_ac694eae12e92dfb: function(arg0) {
            queueMicrotask(arg0);
        },
        __wbg_queueMicrotask_be5fe34a8f4cad4d: function(arg0) {
            const ret = arg0.queueMicrotask;
            return ret;
        },
        __wbg_readyState_fe79161592fd15ce: function(arg0) {
            const ret = arg0.readyState;
            return ret;
        },
        __wbg_resolve_020f95d838c6ef25: function(arg0) {
            const ret = Promise.resolve(arg0);
            return ret;
        },
        __wbg_send_76be66dda8ee844c: function() { return handleError(function (arg0, arg1, arg2) {
            arg0.send(getArrayU8FromWasm0(arg1, arg2));
        }, arguments); },
        __wbg_set_14811fdb285b1915: function() { return handleError(function (arg0, arg1, arg2) {
            arg0.set(arg1 >>> 0, arg2);
        }, arguments); },
        __wbg_set_8155bb79a948541b: function() { return handleError(function (arg0, arg1, arg2) {
            const ret = Reflect.set(arg0, arg1, arg2);
            return ret;
        }, arguments); },
        __wbg_set_862c439a342a8818: function(arg0, arg1, arg2) {
            arg0.set(arg1, arg2 >>> 0);
        },
        __wbg_set_b9b5b5cb7b495037: function(arg0, arg1, arg2) {
            arg0.set(getArrayU8FromWasm0(arg1, arg2));
        },
        __wbg_set_binaryType_b701908a03166a9f: function(arg0, arg1) {
            arg0.binaryType = __wbindgen_enum_BinaryType[arg1];
        },
        __wbg_set_onclose_cb71fea4ad9056fc: function(arg0, arg1) {
            arg0.onclose = arg1;
        },
        __wbg_set_onerror_f1491b13f0fea022: function(arg0, arg1) {
            arg0.onerror = arg1;
        },
        __wbg_set_onmessage_065a797dafa9c437: function(arg0, arg1) {
            arg0.onmessage = arg1;
        },
        __wbg_set_value_1b7bd2bc4ef248bb: function(arg0, arg1) {
            arg0.value = arg1;
        },
        __wbg_static_accessor_GLOBAL_THIS_466428f93b4eaa76: function() {
            const ret = typeof globalThis === 'undefined' ? null : globalThis;
            return isLikeNone(ret) ? 0 : addToExternrefTable0(ret);
        },
        __wbg_static_accessor_GLOBAL_c7aea38d4de089bc: function() {
            const ret = typeof global === 'undefined' ? null : global;
            return isLikeNone(ret) ? 0 : addToExternrefTable0(ret);
        },
        __wbg_static_accessor_SELF_42d4fae05e59267a: function() {
            const ret = typeof self === 'undefined' ? null : self;
            return isLikeNone(ret) ? 0 : addToExternrefTable0(ret);
        },
        __wbg_static_accessor_WINDOW_e0db14a0eba6a812: function() {
            const ret = typeof window === 'undefined' ? null : window;
            return isLikeNone(ret) ? 0 : addToExternrefTable0(ret);
        },
        __wbg_store_523722c647247b86: function() { return handleError(function (arg0, arg1, arg2) {
            const ret = Atomics.store(arg0, arg1 >>> 0, arg2);
            return ret;
        }, arguments); },
        __wbg_subarray_a4cc58201c7359fd: function(arg0, arg1, arg2) {
            const ret = arg0.subarray(arg1 >>> 0, arg2 >>> 0);
            return ret;
        },
        __wbg_then_7026b513a94278a8: function(arg0, arg1) {
            const ret = arg0.then(arg1);
            return ret;
        },
        __wbg_then_72819b8d4e081fb5: function(arg0, arg1, arg2) {
            const ret = arg0.then(arg1, arg2);
            return ret;
        },
        __wbg_timeOrigin_6ff1a15fad0a38af: function(arg0) {
            const ret = arg0.timeOrigin;
            return ret;
        },
        __wbg_value_728796e3a1723ff8: function(arg0) {
            const ret = arg0.value;
            return ret;
        },
        __wbg_wait_5f03a1b29e76c8cb: function() { return handleError(function (arg0, arg1, arg2, arg3) {
            const ret = Atomics.wait(arg0, arg1 >>> 0, arg2, arg3);
            return ret;
        }, arguments); },
        __wbg_wait_cc2c3d3780fc5c7c: function() { return handleError(function (arg0, arg1, arg2, arg3) {
            const ret = Atomics.wait(arg0, arg1 >>> 0, arg2, arg3);
            return ret;
        }, arguments); },
        __wbindgen_cast_0000000000000001: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [Externref], shim_idx: 56, ret: Result(Unit), inner_ret: Some(Result(Unit)) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___wasm_bindgen_5257fc0973cf488f___JsValue__core_5fe7677b72d1ce61___result__Result_____wasm_bindgen_5257fc0973cf488f___JsError___true_);
            return ret;
        },
        __wbindgen_cast_0000000000000002: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [Externref], shim_idx: 867, ret: Unit, inner_ret: Some(Unit) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___wasm_bindgen_5257fc0973cf488f___JsValue______true_);
            return ret;
        },
        __wbindgen_cast_0000000000000003: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [I32, I32, I32], shim_idx: 875, ret: I32, inner_ret: Some(I32) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__i32__true_);
            return ret;
        },
        __wbindgen_cast_0000000000000004: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [I32, I32, U32], shim_idx: 875, ret: I32, inner_ret: Some(I32) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__i32__true__3);
            return ret;
        },
        __wbindgen_cast_0000000000000005: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [I32, I32], shim_idx: 873, ret: I32, inner_ret: Some(I32) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__true_);
            return ret;
        },
        __wbindgen_cast_0000000000000006: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [I32, U32, U32, U32], shim_idx: 880, ret: I32, inner_ret: Some(I32) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__u32__u32__u32__i32__true_);
            return ret;
        },
        __wbindgen_cast_0000000000000007: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [I32, U32, U32], shim_idx: 875, ret: I32, inner_ret: Some(I32) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__i32__true__6);
            return ret;
        },
        __wbindgen_cast_0000000000000008: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [I32, U32], shim_idx: 873, ret: I32, inner_ret: Some(I32) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__true__7);
            return ret;
        },
        __wbindgen_cast_0000000000000009: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [I32], shim_idx: 867, ret: Unit, inner_ret: Some(Unit) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___wasm_bindgen_5257fc0973cf488f___JsValue______true__8);
            return ret;
        },
        __wbindgen_cast_000000000000000a: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [I32], shim_idx: 870, ret: I32, inner_ret: Some(I32) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__true_);
            return ret;
        },
        __wbindgen_cast_000000000000000b: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [NamedExternref("MessageEvent")], shim_idx: 867, ret: Unit, inner_ret: Some(Unit) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___wasm_bindgen_5257fc0973cf488f___JsValue______true__10);
            return ret;
        },
        __wbindgen_cast_000000000000000c: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [U32, I32, I32], shim_idx: 875, ret: I32, inner_ret: Some(I32) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__i32__true__11);
            return ret;
        },
        __wbindgen_cast_000000000000000d: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [U32, I32, I64, U64], shim_idx: 885, ret: Result(I32), inner_ret: Some(Result(I32)) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___u32__i32__i64__u64__core_5fe7677b72d1ce61___result__Result_i32__wasm_bindgen_5257fc0973cf488f___JsValue___true_);
            return ret;
        },
        __wbindgen_cast_000000000000000e: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [U32, I32, U32, I32], shim_idx: 883, ret: Unit, inner_ret: Some(Unit) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___u32__i32__u32__i32______true_);
            return ret;
        },
        __wbindgen_cast_000000000000000f: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [U32, I64, I64, U64], shim_idx: 893, ret: Result(I32), inner_ret: Some(Result(I32)) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___u32__i64__i64__u64__core_5fe7677b72d1ce61___result__Result_i32__wasm_bindgen_5257fc0973cf488f___JsValue___true_);
            return ret;
        },
        __wbindgen_cast_0000000000000010: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [U32, I64, U32], shim_idx: 891, ret: I32, inner_ret: Some(I32) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___u32__i64__u32__i32__true_);
            return ret;
        },
        __wbindgen_cast_0000000000000011: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [U32, U32, I32], shim_idx: 875, ret: I32, inner_ret: Some(I32) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__i32__true__16);
            return ret;
        },
        __wbindgen_cast_0000000000000012: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [U32, U32, U32, U32], shim_idx: 880, ret: I32, inner_ret: Some(I32) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__u32__u32__u32__i32__true__17);
            return ret;
        },
        __wbindgen_cast_0000000000000013: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [U32, U32, U32], shim_idx: 875, ret: I32, inner_ret: Some(I32) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__i32__true__18);
            return ret;
        },
        __wbindgen_cast_0000000000000014: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [U32, U32], shim_idx: 873, ret: I32, inner_ret: Some(I32) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__true__19);
            return ret;
        },
        __wbindgen_cast_0000000000000015: function(arg0, arg1) {
            // Cast intrinsic for `Closure(Closure { owned: true, function: Function { arguments: [], shim_idx: 895, ret: I32, inner_ret: Some(I32) }, mutable: true }) -> Externref`.
            const ret = makeMutClosure(arg0, arg1, wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__true_);
            return ret;
        },
        __wbindgen_cast_0000000000000016: function(arg0) {
            // Cast intrinsic for `F64 -> Externref`.
            const ret = arg0;
            return ret;
        },
        __wbindgen_cast_0000000000000017: function(arg0, arg1) {
            // Cast intrinsic for `Ref(String) -> Externref`.
            const ret = getStringFromWasm0(arg0, arg1);
            return ret;
        },
        __wbindgen_init_externref_table: function() {
            const table = wasm.__wbindgen_externrefs;
            const offset = table.grow(4);
            table.set(0, undefined);
            table.set(offset + 0, undefined);
            table.set(offset + 1, null);
            table.set(offset + 2, true);
            table.set(offset + 3, false);
        },
    };
    return {
        __proto__: null,
        "./ash_browser_bg.js": import0,
    };
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__true_(arg0, arg1) {
    const ret = wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__true_(arg0, arg1);
    return ret;
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___wasm_bindgen_5257fc0973cf488f___JsValue______true_(arg0, arg1, arg2) {
    wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___wasm_bindgen_5257fc0973cf488f___JsValue______true_(arg0, arg1, arg2);
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___wasm_bindgen_5257fc0973cf488f___JsValue______true__10(arg0, arg1, arg2) {
    wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___wasm_bindgen_5257fc0973cf488f___JsValue______true__10(arg0, arg1, arg2);
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___wasm_bindgen_5257fc0973cf488f___JsValue__core_5fe7677b72d1ce61___result__Result_____wasm_bindgen_5257fc0973cf488f___JsError___true_(arg0, arg1, arg2) {
    const ret = wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___wasm_bindgen_5257fc0973cf488f___JsValue__core_5fe7677b72d1ce61___result__Result_____wasm_bindgen_5257fc0973cf488f___JsError___true_(arg0, arg1, arg2);
    if (ret[1]) {
        throw takeFromExternrefTable0(ret[0]);
    }
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___js_sys_9b95b060f9ea9f45___Function_fn_wasm_bindgen_5257fc0973cf488f___JsValue_____wasm_bindgen_5257fc0973cf488f___sys__Undefined___js_sys_9b95b060f9ea9f45___Function_fn_wasm_bindgen_5257fc0973cf488f___JsValue_____wasm_bindgen_5257fc0973cf488f___sys__Undefined_______true_(arg0, arg1, arg2, arg3) {
    wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___js_sys_9b95b060f9ea9f45___Function_fn_wasm_bindgen_5257fc0973cf488f___JsValue_____wasm_bindgen_5257fc0973cf488f___sys__Undefined___js_sys_9b95b060f9ea9f45___Function_fn_wasm_bindgen_5257fc0973cf488f___JsValue_____wasm_bindgen_5257fc0973cf488f___sys__Undefined_______true_(arg0, arg1, arg2, arg3);
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___wasm_bindgen_5257fc0973cf488f___JsValue______true__8(arg0, arg1, arg2) {
    wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___wasm_bindgen_5257fc0973cf488f___JsValue______true__8(arg0, arg1, arg2);
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__true_(arg0, arg1, arg2) {
    const ret = wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__true_(arg0, arg1, arg2);
    return ret;
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___u32__i64__i64__u64__core_5fe7677b72d1ce61___result__Result_i32__wasm_bindgen_5257fc0973cf488f___JsValue___true_(arg0, arg1, arg2, arg3, arg4, arg5) {
    const ret = wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___u32__i64__i64__u64__core_5fe7677b72d1ce61___result__Result_i32__wasm_bindgen_5257fc0973cf488f___JsValue___true_(arg0, arg1, arg2, arg3, arg4, arg5);
    if (ret[2]) {
        throw takeFromExternrefTable0(ret[1]);
    }
    return ret[0];
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___u32__i64__u32__i32__true_(arg0, arg1, arg2, arg3, arg4) {
    const ret = wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___u32__i64__u32__i32__true_(arg0, arg1, arg2, arg3, arg4);
    return ret;
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__true_(arg0, arg1, arg2, arg3) {
    const ret = wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__true_(arg0, arg1, arg2, arg3);
    return ret;
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__true__7(arg0, arg1, arg2, arg3) {
    const ret = wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__true__7(arg0, arg1, arg2, arg3);
    return ret;
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__true__19(arg0, arg1, arg2, arg3) {
    const ret = wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__true__19(arg0, arg1, arg2, arg3);
    return ret;
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___u32__i32__i64__u64__core_5fe7677b72d1ce61___result__Result_i32__wasm_bindgen_5257fc0973cf488f___JsValue___true_(arg0, arg1, arg2, arg3, arg4, arg5) {
    const ret = wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___u32__i32__i64__u64__core_5fe7677b72d1ce61___result__Result_i32__wasm_bindgen_5257fc0973cf488f___JsValue___true_(arg0, arg1, arg2, arg3, arg4, arg5);
    if (ret[2]) {
        throw takeFromExternrefTable0(ret[1]);
    }
    return ret[0];
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__i32__true_(arg0, arg1, arg2, arg3, arg4) {
    const ret = wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__i32__true_(arg0, arg1, arg2, arg3, arg4);
    return ret;
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__i32__true__3(arg0, arg1, arg2, arg3, arg4) {
    const ret = wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__i32__true__3(arg0, arg1, arg2, arg3, arg4);
    return ret;
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__i32__true__6(arg0, arg1, arg2, arg3, arg4) {
    const ret = wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__i32__true__6(arg0, arg1, arg2, arg3, arg4);
    return ret;
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__i32__true__11(arg0, arg1, arg2, arg3, arg4) {
    const ret = wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__i32__true__11(arg0, arg1, arg2, arg3, arg4);
    return ret;
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__i32__true__16(arg0, arg1, arg2, arg3, arg4) {
    const ret = wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__i32__true__16(arg0, arg1, arg2, arg3, arg4);
    return ret;
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__i32__true__18(arg0, arg1, arg2, arg3, arg4) {
    const ret = wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__i32__i32__i32__true__18(arg0, arg1, arg2, arg3, arg4);
    return ret;
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___u32__i32__u32__i32______true_(arg0, arg1, arg2, arg3, arg4, arg5) {
    wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___u32__i32__u32__i32______true_(arg0, arg1, arg2, arg3, arg4, arg5);
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__u32__u32__u32__i32__true_(arg0, arg1, arg2, arg3, arg4, arg5) {
    const ret = wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__u32__u32__u32__i32__true_(arg0, arg1, arg2, arg3, arg4, arg5);
    return ret;
}

function wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__u32__u32__u32__i32__true__17(arg0, arg1, arg2, arg3, arg4, arg5) {
    const ret = wasm.wasm_bindgen_5257fc0973cf488f___convert__closures_____invoke___i32__u32__u32__u32__i32__true__17(arg0, arg1, arg2, arg3, arg4, arg5);
    return ret;
}


const __wbindgen_enum_BinaryType = ["blob", "arraybuffer"];
const OutcomeFinalization = (typeof FinalizationRegistry === 'undefined')
    ? { register: () => {}, unregister: () => {} }
    : new FinalizationRegistry(ptr => wasm.__wbg_outcome_free(ptr, 1));

function addToExternrefTable0(obj) {
    const idx = wasm.__externref_table_alloc();
    wasm.__wbindgen_externrefs.set(idx, obj);
    return idx;
}

const CLOSURE_DTORS = (typeof FinalizationRegistry === 'undefined')
    ? { register: () => {}, unregister: () => {} }
    : new FinalizationRegistry(state => wasm.__wbindgen_destroy_closure(state.a, state.b));

function debugString(val) {
    // primitive types
    const type = typeof val;
    if (type == 'number' || type == 'boolean' || val == null) {
        return  `${val}`;
    }
    if (type == 'string') {
        return `"${val}"`;
    }
    if (type == 'symbol') {
        const description = val.description;
        if (description == null) {
            return 'Symbol';
        } else {
            return `Symbol(${description})`;
        }
    }
    if (type == 'function') {
        const name = val.name;
        if (typeof name == 'string' && name.length > 0) {
            return `Function(${name})`;
        } else {
            return 'Function';
        }
    }
    // objects
    if (Array.isArray(val)) {
        const length = val.length;
        let debug = '[';
        if (length > 0) {
            debug += debugString(val[0]);
        }
        for(let i = 1; i < length; i++) {
            debug += ', ' + debugString(val[i]);
        }
        debug += ']';
        return debug;
    }
    // Test for built-in
    const builtInMatches = /\[object ([^\]]+)\]/.exec(toString.call(val));
    let className;
    if (builtInMatches && builtInMatches.length > 1) {
        className = builtInMatches[1];
    } else {
        // Failed to match the standard '[object ClassName]'
        return toString.call(val);
    }
    if (className == 'Object') {
        // we're a user defined class or Object
        // JSON.stringify avoids problems with cycles, and is generally much
        // easier than looping through ownProperties of `val`.
        try {
            return 'Object(' + JSON.stringify(val) + ')';
        } catch (_) {
            return 'Object';
        }
    }
    // errors
    if (val instanceof Error) {
        return `${val.name}: ${val.message}\n${val.stack}`;
    }
    // TODO we could test for more things here, like `Set`s and `Map`s.
    return className;
}

function getArrayU8FromWasm0(ptr, len) {
    ptr = ptr >>> 0;
    return getUint8ArrayMemory0().subarray(ptr / 1, ptr / 1 + len);
}

let cachedDataViewMemory0 = null;
function getDataViewMemory0() {
    if (cachedDataViewMemory0 === null || cachedDataViewMemory0.buffer.detached === true || (cachedDataViewMemory0.buffer.detached === undefined && cachedDataViewMemory0.buffer !== wasm.memory.buffer)) {
        cachedDataViewMemory0 = new DataView(wasm.memory.buffer);
    }
    return cachedDataViewMemory0;
}

function getStringFromWasm0(ptr, len) {
    return decodeText(ptr >>> 0, len);
}

let cachedUint8ArrayMemory0 = null;
function getUint8ArrayMemory0() {
    if (cachedUint8ArrayMemory0 === null || cachedUint8ArrayMemory0.byteLength === 0) {
        cachedUint8ArrayMemory0 = new Uint8Array(wasm.memory.buffer);
    }
    return cachedUint8ArrayMemory0;
}

function handleError(f, args) {
    try {
        return f.apply(this, args);
    } catch (e) {
        const idx = addToExternrefTable0(e);
        wasm.__wbindgen_exn_store(idx);
    }
}

function isLikeNone(x) {
    return x === undefined || x === null;
}

function makeMutClosure(arg0, arg1, f) {
    const state = { a: arg0, b: arg1, cnt: 1 };
    const real = (...args) => {

        // First up with a closure we increment the internal reference
        // count. This ensures that the Rust closure environment won't
        // be deallocated while we're invoking it.
        state.cnt++;
        const a = state.a;
        state.a = 0;
        try {
            return f(a, state.b, ...args);
        } finally {
            state.a = a;
            real._wbg_cb_unref();
        }
    };
    real._wbg_cb_unref = () => {
        if (--state.cnt === 0) {
            wasm.__wbindgen_destroy_closure(state.a, state.b);
            state.a = 0;
            CLOSURE_DTORS.unregister(state);
        }
    };
    CLOSURE_DTORS.register(real, state, state);
    return real;
}

function passArrayJsValueToWasm0(array, malloc) {
    const ptr = malloc(array.length * 4, 4) >>> 0;
    for (let i = 0; i < array.length; i++) {
        const add = addToExternrefTable0(array[i]);
        getDataViewMemory0().setUint32(ptr + 4 * i, add, true);
    }
    WASM_VECTOR_LEN = array.length;
    return ptr;
}

function passStringToWasm0(arg, malloc, realloc) {
    if (realloc === undefined) {
        const buf = cachedTextEncoder.encode(arg);
        const ptr = malloc(buf.length, 1) >>> 0;
        getUint8ArrayMemory0().subarray(ptr, ptr + buf.length).set(buf);
        WASM_VECTOR_LEN = buf.length;
        return ptr;
    }

    let len = arg.length;
    let ptr = malloc(len, 1) >>> 0;

    const mem = getUint8ArrayMemory0();

    let offset = 0;

    for (; offset < len; offset++) {
        const code = arg.charCodeAt(offset);
        if (code > 0x7F) break;
        mem[ptr + offset] = code;
    }
    if (offset !== len) {
        if (offset !== 0) {
            arg = arg.slice(offset);
        }
        ptr = realloc(ptr, len, len = offset + arg.length * 3, 1) >>> 0;
        const view = getUint8ArrayMemory0().subarray(ptr + offset, ptr + len);
        const ret = cachedTextEncoder.encodeInto(arg, view);

        offset += ret.written;
        ptr = realloc(ptr, len, offset, 1) >>> 0;
    }

    WASM_VECTOR_LEN = offset;
    return ptr;
}

function takeFromExternrefTable0(idx) {
    const value = wasm.__wbindgen_externrefs.get(idx);
    wasm.__externref_table_dealloc(idx);
    return value;
}

let cachedTextDecoder = new TextDecoder('utf-8', { ignoreBOM: true, fatal: true });
cachedTextDecoder.decode();
const MAX_SAFARI_DECODE_BYTES = 2146435072;
let numBytesDecoded = 0;
function decodeText(ptr, len) {
    numBytesDecoded += len;
    if (numBytesDecoded >= MAX_SAFARI_DECODE_BYTES) {
        cachedTextDecoder = new TextDecoder('utf-8', { ignoreBOM: true, fatal: true });
        cachedTextDecoder.decode();
        numBytesDecoded = len;
    }
    return cachedTextDecoder.decode(getUint8ArrayMemory0().subarray(ptr, ptr + len));
}

const cachedTextEncoder = new TextEncoder();

if (!('encodeInto' in cachedTextEncoder)) {
    cachedTextEncoder.encodeInto = function (arg, view) {
        const buf = cachedTextEncoder.encode(arg);
        view.set(buf);
        return {
            read: arg.length,
            written: buf.length
        };
    };
}

let WASM_VECTOR_LEN = 0;

let wasmModule, wasmInstance, wasm;
function __wbg_finalize_init(instance, module) {
    wasmInstance = instance;
    wasm = instance.exports;
    wasmModule = module;
    cachedDataViewMemory0 = null;
    cachedUint8ArrayMemory0 = null;
    wasm.__wbindgen_start();
    return wasm;
}

async function __wbg_load(module, imports) {
    if (typeof Response === 'function' && module instanceof Response) {
        if (!module.ok) {
            throw new Error(`failed to fetch Wasm: ${module.status} ${module.statusText} fetching '${module.url}'`);
        }

        if (typeof WebAssembly.instantiateStreaming === 'function') {
            try {
                return await WebAssembly.instantiateStreaming(module, imports);
            } catch (e) {
                const validResponse = expectedResponseType(module.type);

                if (validResponse && module.headers.get('Content-Type') !== 'application/wasm') {
                    console.warn("`WebAssembly.instantiateStreaming` failed because your server does not serve Wasm with `application/wasm` MIME type. Falling back to `WebAssembly.instantiate` which is slower. Original error:\n", e);

                } else { throw e; }
            }
        }

        const bytes = await module.arrayBuffer();
        return await WebAssembly.instantiate(bytes, imports);
    } else {
        const instance = await WebAssembly.instantiate(module, imports);

        if (instance instanceof WebAssembly.Instance) {
            return { instance, module };
        } else {
            return instance;
        }
    }

    function expectedResponseType(type) {
        switch (type) {
            case 'basic': case 'cors': case 'default': return true;
        }
        return false;
    }
}

function initSync(module) {
    if (wasm !== undefined) return wasm;


    if (module !== undefined) {
        if (Object.getPrototypeOf(module) === Object.prototype) {
            ({module} = module)
        } else {
            console.warn('using deprecated parameters for `initSync()`; pass a single object instead')
        }
    }

    const imports = __wbg_get_imports();
    if (!(module instanceof WebAssembly.Module)) {
        module = new WebAssembly.Module(module);
    }
    const instance = new WebAssembly.Instance(module, imports);
    return __wbg_finalize_init(instance, module);
}

async function __wbg_init(module_or_path) {
    if (wasm !== undefined) return wasm;


    if (module_or_path !== undefined) {
        if (Object.getPrototypeOf(module_or_path) === Object.prototype) {
            ({module_or_path} = module_or_path)
        } else {
            console.warn('using deprecated parameters for the initialization function; pass a single object instead')
        }
    }

    if (module_or_path === undefined) {
        module_or_path = new URL('ash_browser_bg.wasm', import.meta.url);
    }
    const imports = __wbg_get_imports();

    if (typeof module_or_path === 'string' || (typeof Request === 'function' && module_or_path instanceof Request) || (typeof URL === 'function' && module_or_path instanceof URL)) {
        module_or_path = fetch(module_or_path);
    }

    const { instance, module } = await __wbg_load(await module_or_path, imports);

    return __wbg_finalize_init(instance, module);
}

export { initSync, __wbg_init as default };
