# Copyright (c) 2019, NVIDIA CORPORATION. All rights reserved.
# See file LICENSE for terms.
# cython: language_level=3

from libc.stdint cimport uintptr_t
import logging
import asyncio
from core_dep cimport *
from ..exceptions import (
    UCXError,
    UCXConfigError,
    UCXCanceled,
)
from .utils import get_buffer_data


cdef assert_ucs_status(ucs_status_t status, msg_context=None):
    if status != UCS_OK:
        msg = "[%s] " % msg_context if msg_context is not None else ""
        msg += ucs_status_string(status).decode("utf-8")
        raise UCXError(msg)


cdef ucp_config_t * _read_ucx_config(dict user_options) except *:
    """
    Reads the UCX config and returns a config handle,
    which should freed using `ucp_config_release()`.
    """
    cdef ucp_config_t *config
    cdef ucs_status_t status
    status = ucp_config_read(NULL, NULL, &config)
    if status != UCS_OK:
        raise UCXConfigError(
            "Couldn't read the UCX options: %s" %
            ucs_status_string(status).decode("utf-8")
        )

    # Modify the UCX configuration options based on `config_dict`
    for k, v in user_options.items():
        status = ucp_config_modify(config, k.encode(), v.encode())
        if status == UCS_ERR_NO_ELEM:
            raise UCXConfigError("Option %s doesn't exist" % k)
        elif status != UCS_OK:
            msg = "Couldn't set option %s to %s: %s" % \
                  (k, v, ucs_status_string(status).decode("utf-8"))
            raise UCXConfigError(msg)
    return config


cdef ucx_config_to_dict(ucp_config_t *config):
    """Returns a dict of a UCX config"""
    cdef char *text
    cdef size_t text_len
    cdef FILE *text_fd = open_memstream(&text, &text_len)
    assert(text_fd != NULL)
    ret = {}
    ucp_config_print(config, text_fd, NULL, UCS_CONFIG_PRINT_CONFIG)
    fflush(text_fd)
    cdef unicode py_text = text.decode()
    for line in py_text.splitlines():
        k, v = line.split("=")
        k = k[len("UCX_"):]
        ret[k] = v
    fclose(text_fd)
    free(text)
    return ret


def get_default_options():
    """
    Returns the current UCX options
    if UCX were to be initialized now.
    """
    cdef ucp_config_t *config = _read_ucx_config({})
    ret = ucx_config_to_dict(config)
    ucp_config_release(config)
    return ret


def get_ucx_version():
    cdef unsigned int a, b, c
    ucp_get_version(&a, &b, &c)
    return (a, b, c)


cdef void _listener_callback(ucp_ep_h ep, void *args):
    from .core import listener_handler
    cdef object cb_kwargs = <dict> args
    asyncio.ensure_future(
        listener_handler(
            int(<uintptr_t><void*>ep),
            cb_kwargs["context"],
            cb_kwargs["worker"],
            cb_kwargs["cb_func"],
            cb_kwargs["guarantee_msg_order"]
        )
    )


cdef class UCXListener:
    cdef:
        ucp_listener_h handle
        uint16_t _port
        object cb_kwargs
        bint initialized

    def __cinit__(
        self,
        UCXWorker worker,
        uint16_t port,
        object cb_kwargs):

        self.initialized = False
        self._port = port
        self.cb_kwargs = cb_kwargs

        cdef ucp_listener_params_t params
        cdef ucp_listener_accept_callback_t _listener_cb = (
            <ucp_listener_accept_callback_t>_listener_callback
        )
        if c_util_get_ucp_listener_params(&params,
                                          port,
                                          _listener_cb,
                                          <void*> cb_kwargs):
            raise MemoryError("Failed allocation of ucp_ep_params_t")

        logging.info("create_listener() - Start listening on port %d" % port)
        cdef ucs_status_t status = ucp_listener_create(
            worker._handle, &params, &self.handle
        )
        c_util_get_ucp_listener_params_free(&params)
        assert_ucs_status(status)
        self.initialized = True

    def port(self):
        return self._port

    def destroy(self):
        if self.initialized:
            self.initialized = False
            ucp_listener_destroy(self.handle)


cdef class UCXContext:
    cdef:
        ucp_context_h _context
        bint _initialized
        object _config

    def __cinit__(self, config_dict):
        cdef ucp_params_t ucp_params
        cdef ucp_worker_params_t worker_params
        cdef ucs_status_t status
        self._initialized = False

        memset(&ucp_params, 0, sizeof(ucp_params))
        ucp_params.field_mask = (UCP_PARAM_FIELD_FEATURES |  # noqa
                                 UCP_PARAM_FIELD_REQUEST_SIZE |  # noqa
                                 UCP_PARAM_FIELD_REQUEST_INIT)

        # We always request UCP_FEATURE_WAKEUP even when in blocking mode
        # See <https://github.com/rapidsai/ucx-py/pull/377>
        ucp_params.features = (UCP_FEATURE_TAG |  # noqa
                               UCP_FEATURE_WAKEUP |  # noqa
                               UCP_FEATURE_STREAM)

        ucp_params.request_size = sizeof(ucp_request)
        ucp_params.request_init = (
            <ucp_request_init_callback_t>ucp_request_reset
        )

        cdef ucp_config_t *config = _read_ucx_config(config_dict)
        status = ucp_init(&ucp_params, config, &self._context)
        assert_ucs_status(status)
        self._initialized = True

        self._config = ucx_config_to_dict(config)
        ucp_config_release(config)

        logging.info("UCP initiated using config: ")
        for k, v in self._config.items():
            logging.info("  %s: %s" % (k, v))

    def destroy(self):
        if self._initialized:
            self._initialized = False
            ucp_cleanup(self._context)

    def get_config(self):
        return self._config


cdef class UCXWorker:
    cdef:
        ucp_worker_h _handle
        bint _initialized

    def __cinit__(self, UCXContext context):
        cdef ucp_params_t ucp_params
        cdef ucp_worker_params_t worker_params
        cdef ucs_status_t status
        self._initialized = False
        memset(&worker_params, 0, sizeof(worker_params))
        worker_params.field_mask = UCP_WORKER_PARAM_FIELD_THREAD_MODE
        worker_params.thread_mode = UCS_THREAD_MODE_MULTI
        status = ucp_worker_create(context._context, &worker_params, &self._handle)
        assert_ucs_status(status)
        self._initialized = True

    def destroy(self):
        if self._initialized:
            self._initialized = False
            ucp_worker_destroy(self._handle)

    def init_blocking_progress_mode(self):
        # In blocking progress mode, we create an epoll file
        # descriptor that we can wait on later.
        cdef ucs_status_t status
        cdef int ucp_epoll_fd
        cdef epoll_event ev
        cdef int err
        status = ucp_worker_get_efd(self._handle, &ucp_epoll_fd)
        assert_ucs_status(status)
        self.arm()
        epoll_fd = epoll_create(1)
        assert(epoll_fd != -1)
        ev.data.fd = ucp_epoll_fd
        ev.events = EPOLLIN
        err = epoll_ctl(epoll_fd, EPOLL_CTL_ADD, ucp_epoll_fd, &ev)
        assert(err == 0)
        return epoll_fd

    def arm(self):
        cdef ucs_status_t status
        status = ucp_worker_arm(self._handle)
        if status == UCS_ERR_BUSY:
            return False
        assert_ucs_status(status)
        return True

    def ep_create(self, str ip_address, port):
        cdef ucp_ep_params_t params
        if c_util_get_ucp_ep_params(&params, ip_address.encode(), port):
            raise MemoryError("Failed allocation of ucp_ep_params_t")

        cdef ucp_ep_h ucp_ep
        cdef ucs_status_t status = ucp_ep_create(self._handle, &params, &ucp_ep)
        c_util_get_ucp_ep_params_free(&params)
        assert_ucs_status(status)
        return int(<uintptr_t><void*>ucp_ep)

    def progress(self):
        while ucp_worker_progress(self._handle) != 0:
            pass

    @property
    def handle(self):
        return int(<uintptr_t><void*>self._handle)

    def request_cancel(self, ucp_request_as_int):
        ucp_request_cancel(
            self._handle,
            <void*><uintptr_t>ucp_request_as_int
        )



cdef create_future_from_comm_status(ucs_status_ptr_t status,
                                    int64_t expected_receive,
                                    pending_msg):
    if pending_msg is not None:
        log_str = pending_msg.get('log', None)
    else:
        log_str = None

    ret = asyncio.get_event_loop().create_future()
    msg = "Comm Error%s " %(" \"%s\":" % log_str if log_str else ":")
    if UCS_PTR_STATUS(status) == UCS_OK:
        ret.set_result(True)
    elif UCS_PTR_IS_ERR(status):
        msg += ucs_status_string(UCS_PTR_STATUS(status)).decode("utf-8")
        ret.set_exception(UCXError(msg))
    else:
        req = <ucp_request*> status
        if req.finished:  # The callback function has already handle the request
            if req.received != -1 and req.received != expected_receive:
                msg += "length mismatch: %d (got) != %d (expected)" % (
                    req.received, expected_receive
                )
                ret.set_exception(UCXError(msg))
            else:
                ret.set_result(True)
            ucp_request_reset(req)
            ucp_request_free(req)
        else:
            # The callback function has not been called yet.
            # We fill `ucp_request` for the callback function to use
            Py_INCREF(ret)
            req.future = <PyObject*> ret
            req.expected_receive = expected_receive
            if pending_msg is not None:
                pending_msg['future'] = ret
                pending_msg['ucp_request'] = int(<uintptr_t><void*>req)
                pending_msg['expected_receive'] = expected_receive
            Py_INCREF(log_str)
            req.log_str = <PyObject*> log_str
    return ret


cdef void _send_callback(void *request, ucs_status_t status):
    cdef ucp_request *req = <ucp_request*> request
    if req.future == NULL:
        # This callback function was called before ucp_tag_send_nb() returned
        req.finished = True
        return
    cdef object future = <object> req.future
    cdef object log_str = <object> req.log_str
    if asyncio.get_event_loop().is_closed():
        pass
    elif status == UCS_ERR_CANCELED:
        future.set_exception(UCXCanceled())
    elif status != UCS_OK:
        msg = "Error sending%s " %(" \"%s\":" % log_str if log_str else ":")
        msg += ucs_status_string(status).decode("utf-8")
        future.set_exception(UCXError(msg))
    else:
        future.set_result(True)
    Py_DECREF(future)
    Py_DECREF(log_str)
    ucp_request_reset(request)
    ucp_request_free(request)


def tag_send(uintptr_t ucp_ep, buffer, size_t nbytes,
             ucp_tag_t tag, pending_msg=None):
    cdef ucp_ep_h ep = <ucp_ep_h><uintptr_t>ucp_ep
    cdef void *data = <void*><uintptr_t>(get_buffer_data(buffer,
                                         check_writable=False))
    cdef ucp_send_callback_t _send_cb = <ucp_send_callback_t>_send_callback
    cdef ucs_status_ptr_t status = ucp_tag_send_nb(ep,
                                                   data,
                                                   nbytes,
                                                   ucp_dt_make_contig(1),
                                                   tag,
                                                   _send_cb)
    return create_future_from_comm_status(status, nbytes, pending_msg)


cdef void _tag_recv_callback(void *request, ucs_status_t status,
                             ucp_tag_recv_info_t *info):
    cdef ucp_request *req = <ucp_request*> request
    if req.future == NULL:
        # This callback function was called before ucp_tag_recv_nb() returned
        req.finished = True
        req.received = info.length
        return
    cdef object future = <object> req.future
    cdef object log_str = <object> req.log_str
    msg = "Error receiving%s " %(" \"%s\":" % log_str if log_str else ":")
    if asyncio.get_event_loop().is_closed():
        pass
    elif status == UCS_ERR_CANCELED:
        future.set_exception(UCXCanceled())
    elif status != UCS_OK:
        msg += ucs_status_string(status).decode("utf-8")
        future.set_exception(UCXError(msg))
    elif info.length != req.expected_receive:
        msg += "length mismatch: %d (got) != %d (expected)" % (
            info.length, req.expected_receive
        )
        future.set_exception(UCXError(msg))
    else:
        future.set_result(True)
    Py_DECREF(future)
    Py_DECREF(log_str)
    ucp_request_reset(request)
    ucp_request_free(request)


def tag_recv(UCXWorker worker, buffer, size_t nbytes,
             ucp_tag_t tag, pending_msg=None):
    cdef void *data = <void*><uintptr_t>(get_buffer_data(buffer,
                                         check_writable=True))
    cdef ucp_tag_recv_callback_t _tag_recv_cb = (
        <ucp_tag_recv_callback_t>_tag_recv_callback
    )
    cdef ucs_status_ptr_t status = ucp_tag_recv_nb(worker._handle,
                                                   data,
                                                   nbytes,
                                                   ucp_dt_make_contig(1),
                                                   tag,
                                                   -1,
                                                   _tag_recv_cb)
    return create_future_from_comm_status(status, nbytes, pending_msg)


def stream_send(uintptr_t ucp_ep, buffer, size_t nbytes, pending_msg=None):
    cdef ucp_ep_h ep = <ucp_ep_h><uintptr_t>ucp_ep
    cdef void *data = <void*><uintptr_t>(get_buffer_data(buffer,
                                         check_writable=False))
    cdef ucp_send_callback_t _send_cb = <ucp_send_callback_t>_send_callback
    cdef ucs_status_ptr_t status = ucp_stream_send_nb(ep,
                                                      data,
                                                      nbytes,
                                                      ucp_dt_make_contig(1),
                                                      _send_cb,
                                                      0)
    return create_future_from_comm_status(status, nbytes, pending_msg)


cdef void _stream_recv_callback(void *request, ucs_status_t status,
                                size_t length):
    cdef ucp_request *req = <ucp_request*> request
    if req.future == NULL:
        # This callback function was called before ucp_stream_recv_nb() returned
        req.finished = True
        req.received = length
        return
    cdef object future = <object> req.future
    cdef object log_str = <object> req.log_str
    msg = "Error receiving %s" %(" \"%s\":" % log_str if log_str else ":")
    if asyncio.get_event_loop().is_closed():
        pass
    elif status == UCS_ERR_CANCELED:
        future.set_exception(UCXCanceled())
    elif status != UCS_OK:
        msg += ucs_status_string(status).decode("utf-8")
        future.set_exception(UCXError(msg))
    elif length != req.expected_receive:
        msg += "length mismatch: %d (got) != %d (expected)" % (
            length, req.expected_receive)
        future.set_exception(UCXError(msg))
    else:
        future.set_result(True)
    Py_DECREF(future)
    Py_DECREF(log_str)
    ucp_request_reset(request)
    ucp_request_free(request)


def stream_recv(uintptr_t ucp_ep, buffer, size_t nbytes, pending_msg=None):
    cdef ucp_ep_h ep = <ucp_ep_h><uintptr_t>ucp_ep
    cdef void *data = <void*><uintptr_t>(get_buffer_data(buffer,
                                         check_writable=True))
    cdef size_t length
    cdef ucp_request *req
    cdef ucp_stream_recv_callback_t _stream_recv_cb = (
        <ucp_stream_recv_callback_t>_stream_recv_callback
    )
    cdef ucs_status_ptr_t status = ucp_stream_recv_nb(ep,
                                                      data,
                                                      nbytes,
                                                      ucp_dt_make_contig(1),
                                                      _stream_recv_cb,
                                                      &length,
                                                      0)
    return create_future_from_comm_status(status, nbytes, pending_msg)