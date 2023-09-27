
use std::os::raw::{c_char, c_int, c_void};
use std::{slice, thread, time};
use std::sync::Arc;
use std::cell::RefCell;
use std::ffi::CString;

pub type WakuCallback =
    unsafe extern "C" fn(
        *const c_char,
        usize,
        *const c_void,
    );

extern "C" {
    pub fn waku_init(
        cb: WakuCallback,
        user_data: *const c_void,
    ) -> *mut c_void;

    pub fn waku_new(
        ctx: *mut *mut c_void,
        config_json: *const u8,
        cb: WakuCallback,
    ) -> c_int;

    pub fn waku_version(
        ctx: *mut *mut c_void,
        cb: WakuCallback,
    ) -> c_int;

    pub fn waku_default_pubsub_topic(
        ctx: *mut *mut c_void,
        cb: WakuCallback,
    ) -> *mut c_void;

    pub fn waku_set_user_data(
        ctx: *mut *mut c_void,
        user_data: *const c_void,
    );
}

pub unsafe extern "C" fn trampoline<C>(
    buffer: *const c_char,
    buffer_len: usize,
    data: *const c_void,
) where
    C: FnMut(&str),
{
    let closure = &mut *(data as *mut C);
    
    let buffer_utf8 =
    String::from_utf8(slice::from_raw_parts(buffer as *mut u8, buffer_len)
                    .to_vec())
                    .expect("valid utf8");

    closure(&buffer_utf8);
}

pub fn get_trampoline<C>(_closure: &C) -> WakuCallback
where
    C: FnMut(&str),
{
    trampoline::<C>
}

fn main() {
    let config_json = "\
    { \
        \"host\": \"127.0.0.1\",\
        \"port\": 60000, \
        \"key\": \"0d714a1fada214dead6dc9c7274581ec20ff292451866e7d6d677dc818e8ccd2\", \
        \"relay\": true \
    }";

    unsafe {
        // Initialize the waku library
        let closure = |data: &str| {
            println!("Error initializing the waku library: {data} \n\n");
        };
        let cb = get_trampoline(&closure);
        let mut ctx = waku_init(cb, &closure as *const _ as *const c_void);

        // Create the waku node
        let closure = |data: &str| {
            println!("Error creating waku node {data} \n\n");
        };
        let cb = get_trampoline(&closure);
        let config_json_str = CString::new(config_json).unwrap();
        waku_set_user_data(&mut ctx, &closure as *const _ as *const c_void);
        let _ret = waku_new(
            &mut ctx,
            config_json_str.as_ptr() as *const u8,
            cb,
        );

        // Extracting the current waku version
        let version: Arc<RefCell<String>> = Arc::new(RefCell::new(String::from("")));
        let closure = |data: &str| {
            *version.borrow_mut() = data.to_string();
        };
        let cb = get_trampoline(&closure);
        waku_set_user_data(&mut ctx, &closure as *const _ as *const c_void);
        let _ret = waku_version(
            &mut ctx,
            cb,
        );

        // Extracting the default pubsub topic
        let default_pubsub_topic: Arc<RefCell<String>> = Arc::new(RefCell::new(String::from("")));
        let closure = |data: &str| {
            *default_pubsub_topic.borrow_mut() = data.to_string();
        };
        let cb = get_trampoline(&closure);
        waku_set_user_data(&mut ctx, &closure as *const _ as *const c_void);
        let _ret = waku_default_pubsub_topic(
            &mut ctx,
            cb,
        );

        println!("Version {}", version.borrow());
        println!("Default pubsubTopic {}", default_pubsub_topic.borrow());
    }

    loop {
        thread::sleep(time::Duration::from_millis(10000));
    }
}
