#![allow(non_camel_case_types, dead_code)]

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};

pub type EmacsValue = *mut c_void;
pub type EmacsFinalizer = Option<unsafe extern "C" fn(*mut c_void)>;
pub type EmacsSubr = unsafe extern "C" fn(
    *mut EmacsEnv,
    isize,
    *mut EmacsValue,
    *mut c_void,
) -> EmacsValue;

pub const EMACS_FUNCALL_RETURN: c_int = 0;
pub const EMACS_FUNCALL_SIGNAL: c_int = 1;
pub const EMACS_FUNCALL_THROW: c_int = 2;

#[repr(C)]
pub struct EmacsRuntime {
    pub size: isize,
    pub private_members: *mut c_void,
    pub get_environment: unsafe extern "C" fn(*mut EmacsRuntime) -> *mut EmacsEnv,
}

/// Binary-compatible layout with `struct emacs_env_31` in Emacs 31 `emacs-module.h`.
#[repr(C)]
pub struct EmacsEnv {
    pub size: isize,
    pub private_members: *mut c_void,
    pub make_global_ref: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue) -> EmacsValue,
    pub free_global_ref: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue),
    pub non_local_exit_check: unsafe extern "C" fn(*mut EmacsEnv) -> c_int,
    pub non_local_exit_clear: unsafe extern "C" fn(*mut EmacsEnv),
    pub non_local_exit_get:
        unsafe extern "C" fn(*mut EmacsEnv, *mut EmacsValue, *mut EmacsValue) -> c_int,
    pub non_local_exit_signal: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue, EmacsValue),
    pub non_local_exit_throw: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue, EmacsValue),
    pub make_function: unsafe extern "C" fn(
        *mut EmacsEnv,
        isize,
        isize,
        EmacsSubr,
        *const c_char,
        *mut c_void,
    ) -> EmacsValue,
    pub funcall:
        unsafe extern "C" fn(*mut EmacsEnv, EmacsValue, isize, *mut EmacsValue) -> EmacsValue,
    pub intern: unsafe extern "C" fn(*mut EmacsEnv, *const c_char) -> EmacsValue,
    pub type_of: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue) -> EmacsValue,
    pub is_not_nil: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue) -> bool,
    pub eq: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue, EmacsValue) -> bool,
    pub extract_integer: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue) -> i64,
    pub make_integer: unsafe extern "C" fn(*mut EmacsEnv, i64) -> EmacsValue,
    pub extract_float: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue) -> f64,
    pub make_float: unsafe extern "C" fn(*mut EmacsEnv, f64) -> EmacsValue,
    pub copy_string_contents:
        unsafe extern "C" fn(*mut EmacsEnv, EmacsValue, *mut c_char, *mut isize) -> bool,
    pub make_string: unsafe extern "C" fn(*mut EmacsEnv, *const c_char, isize) -> EmacsValue,
    pub make_user_ptr: unsafe extern "C" fn(*mut EmacsEnv, EmacsFinalizer, *mut c_void) -> EmacsValue,
    pub get_user_ptr: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue) -> *mut c_void,
    pub set_user_ptr: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue, *mut c_void),
    pub get_user_finalizer: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue) -> EmacsFinalizer,
    pub set_user_finalizer: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue, EmacsFinalizer),
    pub vec_get: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue, isize) -> EmacsValue,
    pub vec_set: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue, isize, EmacsValue),
    pub vec_size: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue) -> isize,
    pub should_quit: unsafe extern "C" fn(*mut EmacsEnv) -> bool,
    pub process_input: unsafe extern "C" fn(*mut EmacsEnv) -> c_int,
    pub extract_time: *const c_void,
    pub make_time: *const c_void,
    pub extract_big_integer: *const c_void,
    pub make_big_integer: *const c_void,
    pub get_function_finalizer: *const c_void,
    pub set_function_finalizer: *const c_void,
    pub open_channel: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue) -> c_int,
    pub make_interactive: *const c_void,
    pub make_unibyte_string:
        unsafe extern "C" fn(*mut EmacsEnv, *const c_char, isize) -> EmacsValue,
}

pub struct Env {
    ptr: *mut EmacsEnv,
}

impl Env {
    /// # Safety
    /// `ptr` must be a valid non-null `emacs_env *` passed to a module entry point or subr.
    pub unsafe fn from_raw(ptr: *mut EmacsEnv) -> Self {
        Self { ptr }
    }

    pub fn raw(&self) -> *mut EmacsEnv {
        self.ptr
    }

    pub fn intern(&self, name: &str) -> EmacsValue {
        let c = CString::new(name).unwrap_or_else(|_| CString::new("nil").unwrap());
        unsafe { ((*self.ptr).intern)(self.ptr, c.as_ptr()) }
    }

    pub fn nil(&self) -> EmacsValue {
        self.intern("nil")
    }

    pub fn t(&self) -> EmacsValue {
        self.intern("t")
    }

    pub fn is_not_nil(&self, val: EmacsValue) -> bool {
        unsafe { ((*self.ptr).is_not_nil)(self.ptr, val) }
    }

    pub fn has_non_local_exit(&self) -> bool {
        unsafe { ((*self.ptr).non_local_exit_check)(self.ptr) != EMACS_FUNCALL_RETURN }
    }

    pub fn clear_non_local_exit(&self) {
        unsafe { ((*self.ptr).non_local_exit_clear)(self.ptr) }
    }

    pub fn extract_integer(&self, val: EmacsValue) -> Result<i64, String> {
        let res = unsafe { ((*self.ptr).extract_integer)(self.ptr, val) };
        if self.has_non_local_exit() {
            self.clear_non_local_exit();
            return Err("Expected integer argument".to_string());
        }
        Ok(res)
    }

    pub fn make_integer(&self, n: i64) -> EmacsValue {
        unsafe { ((*self.ptr).make_integer)(self.ptr, n) }
    }

    pub fn extract_float_or_int(&self, val: EmacsValue) -> Result<f64, String> {
        let f = unsafe { ((*self.ptr).extract_float)(self.ptr, val) };
        if !self.has_non_local_exit() {
            return Ok(f);
        }
        self.clear_non_local_exit();
        let i = unsafe { ((*self.ptr).extract_integer)(self.ptr, val) };
        if !self.has_non_local_exit() {
            return Ok(i as f64);
        }
        self.clear_non_local_exit();
        Err("Expected number argument".to_string())
    }

    pub fn extract_string(&self, val: EmacsValue) -> Result<String, String> {
        let mut size: isize = 0;
        let ok = unsafe {
            ((*self.ptr).copy_string_contents)(self.ptr, val, std::ptr::null_mut(), &mut size)
        };
        if !ok || self.has_non_local_exit() || size <= 0 {
            self.clear_non_local_exit();
            return Err("Expected string argument".to_string());
        }
        let mut buf = vec![0u8; size as usize];
        let mut out_size = size;
        let ok2 = unsafe {
            ((*self.ptr).copy_string_contents)(
                self.ptr,
                val,
                buf.as_mut_ptr() as *mut c_char,
                &mut out_size,
            )
        };
        if !ok2 || self.has_non_local_exit() {
            self.clear_non_local_exit();
            return Err("Failed to copy string contents".to_string());
        }
        if buf.last() == Some(&0) {
            buf.pop();
        }
        String::from_utf8(buf).map_err(|e| format!("Invalid UTF-8 string: {e}"))
    }

    pub fn make_string(&self, s: &str) -> EmacsValue {
        unsafe { ((*self.ptr).make_string)(self.ptr, s.as_ptr() as *const c_char, s.len() as isize) }
    }

    pub fn make_unibyte_string(&self, bytes: &[u8]) -> EmacsValue {
        unsafe {
            ((*self.ptr).make_unibyte_string)(
                self.ptr,
                bytes.as_ptr() as *const c_char,
                bytes.len() as isize,
            )
        }
    }

    pub fn make_user_ptr<T>(&self, value: T) -> EmacsValue {
        unsafe extern "C" fn drop_box<T>(ptr: *mut c_void) {
            if !ptr.is_null() {
                drop(Box::from_raw(ptr as *mut T));
            }
        }
        let raw = Box::into_raw(Box::new(value)) as *mut c_void;
        unsafe { ((*self.ptr).make_user_ptr)(self.ptr, Some(drop_box::<T>), raw) }
    }

    /// # Safety
    /// Caller must ensure `val` holds a `user_ptr` created with `make_user_ptr::<T>` and that
    /// the returned reference does not outlive the Emacs module call / borrow rules.
    pub unsafe fn get_user_ptr<'a, T>(&self, val: EmacsValue) -> Result<&'a mut T, String> {
        let raw = ((*self.ptr).get_user_ptr)(self.ptr, val);
        if self.has_non_local_exit() || raw.is_null() {
            self.clear_non_local_exit();
            return Err("Expected valid minder document user-ptr".to_string());
        }
        Ok(&mut *(raw as *mut T))
    }

    pub fn funcall(&self, fn_name: &str, args: &mut [EmacsValue]) -> EmacsValue {
        let sym = self.intern(fn_name);
        unsafe { ((*self.ptr).funcall)(self.ptr, sym, args.len() as isize, args.as_mut_ptr()) }
    }

    pub fn defun(&self, name: &str, min_arity: isize, max_arity: isize, subr: EmacsSubr, doc: &str) {
        let name_c = CString::new(name).unwrap();
        let doc_c = CString::new(doc).unwrap();
        let sym = unsafe { ((*self.ptr).intern)(self.ptr, name_c.as_ptr()) };
        let fun = unsafe {
            ((*self.ptr).make_function)(
                self.ptr,
                min_arity,
                max_arity,
                subr,
                doc_c.as_ptr(),
                std::ptr::null_mut(),
            )
        };
        let mut args = [sym, fun];
        let _ = self.funcall("defalias", &mut args);
    }

    pub fn signal_error(&self, msg: &str) -> EmacsValue {
        let err_sym = self.intern("error");
        let msg_val = self.make_string(msg);
        let mut list_args = [msg_val];
        let data = self.funcall("list", &mut list_args);
        if !self.has_non_local_exit() {
            unsafe { ((*self.ptr).non_local_exit_signal)(self.ptr, err_sym, data) };
        }
        self.nil()
    }

    pub fn error_from_gerror_message(ptr: *const c_char) -> String {
        if ptr.is_null() {
            "unknown GLib error".to_string()
        } else {
            unsafe { CStr::from_ptr(ptr).to_string_lossy().into_owned() }
        }
    }
}
