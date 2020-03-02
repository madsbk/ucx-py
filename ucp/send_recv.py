# Copyright (c) 2019, NVIDIA CORPORATION. All rights reserved.
# See file LICENSE for terms.
# cython: language_level=3

import asyncio

from . import exceptions
from ._libs import ucx_api


def tag_send(ucp_endpoint, buffer, nbytes, tag, pending_msg=None):

    def send_cb(exception, future):
        if asyncio.get_event_loop().is_closed():
            return
        if exception is not None:
            future.set_exception(exception)
        else:
            future.set_result(True)

    ret = asyncio.get_event_loop().create_future()
    req = ucx_api.ucx_tag_send(
        ucp_endpoint, buffer, nbytes, tag, send_cb, (ret,)
    )
    if pending_msg is not None:
        pending_msg['future'] = ret
        pending_msg['ucp_request'] = req
    return ret


def tag_recv(worker, buffer, nbytes, tag, pending_msg=None):

    def recv_cb(exception, received, future, expected_receive):
        if asyncio.get_event_loop().is_closed():
            return
        if exception is not None:
            future.set_exception(exception)
        elif received != expected_receive:
            log_str = None
            msg = "Comm Error%s " %(" \"%s\":" % log_str if log_str else ":")
            msg += "length mismatch: %d (got) != %d (expected)" % (
                received, expected_receive
            )
            future.set_exception(exceptions.UCXError(msg))
        else:
            future.set_result(True)

    ret = asyncio.get_event_loop().create_future()
    req = worker.tag_recv(buffer, nbytes, tag, recv_cb, (ret, nbytes))
    if pending_msg is not None:
        pending_msg['future'] = ret
        pending_msg['ucp_request'] = req
    return ret


def stream_send(ucp_endpoint, buffer, nbytes, pending_msg=None):

    def send_cb(exception, future):
        if asyncio.get_event_loop().is_closed():
            return
        if exception is not None:
            future.set_exception(exception)
        else:
            future.set_result(True)

    ret = asyncio.get_event_loop().create_future()
    req = ucx_api.ucx_stream_send(
        ucp_endpoint, buffer, nbytes, send_cb, (ret,)
    )
    if pending_msg is not None:
        pending_msg['future'] = ret
        pending_msg['ucp_request'] = req
    return ret


def stream_recv(ucp_endpoint, buffer, nbytes, pending_msg=None):

    def recv_cb(exception, received, future, expected_receive):
        if asyncio.get_event_loop().is_closed():
            return
        if exception is not None:
            future.set_exception(exception)
        elif received != expected_receive:
            log_str = None
            msg = "Comm Error%s " %(" \"%s\":" % log_str if log_str else ":")
            msg += "length mismatch: %d (got) != %d (expected)" % (
                received, expected_receive
            )
            future.set_exception(exceptions.UCXError(msg))
        else:
            future.set_result(True)

    ret = asyncio.get_event_loop().create_future()
    req = ucx_api.ucx_stream_recv(
        ucp_endpoint, buffer, nbytes, recv_cb, (ret, nbytes)
    )
    if pending_msg is not None:
        pending_msg['future'] = ret
        pending_msg['ucp_request'] = req
    return ret
