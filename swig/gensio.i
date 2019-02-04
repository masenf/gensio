/*
 *  gensio - A library for abstracting stream I/O
 *  Copyright (C) 2018  Corey Minyard <minyard@acm.org>
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License for more details.
 *
 *  You should have received a copy of the GNU Lesser General Public
 *  License along with this library; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307  USA
 */

%module gensio

%{
#include <string.h>
#include <signal.h>

#include <gensio/gensio.h>
#include <gensio/sergensio.h>
#include <gensio/gensio_selector.h>

#if PYTHON_HAS_POSIX_THREADS
#include <pthread.h>
#define USE_POSIX_THREADS
#endif

struct waiter {
    struct gensio_os_funcs *o;
    struct gensio_waiter *waiter;
};

/*
 * If an exception occurs inside a waiter, we want to stop the wait
 * operation and propagate back.  So we wake it up
 */
#ifdef USE_POSIX_THREADS
static void oom_err(void);
struct gensio_wait_block {
    struct waiter *curr_waiter;
};

static pthread_key_t gensio_thread_key;

static void
gensio_key_del(void *data)
{
    free(data);
}

static struct waiter *
save_waiter(struct waiter *waiter)
{
    struct gensio_wait_block *data = pthread_getspecific(gensio_thread_key);
    struct waiter *prev_waiter;

    if (!data) {
	data = malloc(sizeof(*data));
	if (!data) {
	    oom_err();
	    return NULL;
	}
	memset(data, 0, sizeof(*data));
	pthread_setspecific(gensio_thread_key, data);
    }

    prev_waiter = data->curr_waiter;
    data->curr_waiter = waiter;

    return prev_waiter;
}

static void
restore_waiter(struct waiter *prev_waiter)
{
    struct gensio_wait_block *data = pthread_getspecific(gensio_thread_key);

    data->curr_waiter = prev_waiter;
}

static void
wake_curr_waiter(void)
{
    struct gensio_wait_block *data = pthread_getspecific(gensio_thread_key);

    if (!data)
	return;
    if (data->curr_waiter)
	data->curr_waiter->o->wake(data->curr_waiter->waiter);
}

#else
static struct waiter *curr_waiter;

static struct waiter *
save_waiter(struct waiter *waiter)
{
    struct waiter *prev_waiter = curr_waiter;

    curr_waiter = waiter;
    return prev_waiter;
}

static void
restore_waiter(struct waiter *prev_waiter)
{
    curr_waiter = prev_waiter;
}

static void
wake_curr_waiter(void)
{
    if (curr_waiter)
	curr_waiter->waiter->o->wake(curr_waiter->waiter->waiter);
}
#endif

#include "gensio_python.h"

static int
gensio_do_wait(struct waiter *waiter, unsigned int count,
	       struct timeval *timeout)
{
    int err;
    struct waiter *prev_waiter = save_waiter(waiter);

    do {
	GENSIO_SWIG_C_BLOCK_ENTRY
	err = waiter->o->wait_intr(waiter->waiter, count, timeout);
	GENSIO_SWIG_C_BLOCK_EXIT
	if (check_for_err(err)) {
	    if (prev_waiter)
		prev_waiter->o->wake(prev_waiter->waiter);
	    break;
	}
	if (err == EINTR)
	    continue;
	break;
    } while (1);
    restore_waiter(prev_waiter);

    return err;
}

void get_random_bytes(char **rbuffer, size_t *rbuffer_len, int size_to_allocate)
{
    char *buffer;
    int i;

    buffer = malloc(size_to_allocate);
    if (!buffer) {
	*rbuffer = NULL;
	*rbuffer_len = 0;
	return;
    }
    srandom(time(NULL));

    for (i = 0; i < size_to_allocate; i++)
	buffer[i] = random();
    *rbuffer = buffer;
    *rbuffer_len = size_to_allocate;
}

#ifdef USE_POSIX_THREADS
struct sel_lock_s {
    pthread_mutex_t lock;
};

static sel_lock_t *
gensio_alloc_lock(void *cb_data)
{
    struct sel_lock_s *lock;

    lock = malloc(sizeof(*lock));
    if (!lock)
	return NULL;
    pthread_mutex_init(&lock->lock, NULL);
    return lock;
}

static void
gensio_free_lock(sel_lock_t *lock)
{
    free(lock);
}

static void
gensio_lock(sel_lock_t *lock)
{
    pthread_mutex_lock(&lock->lock);
}

static void
gensio_unlock(sel_lock_t *lock)
{
    pthread_mutex_unlock(&lock->lock);
}

static void
gensio_thread_sighandler(int sig)
{
    /* Nothing to do, signal just wakes things up. */
}
#endif

struct gensio_os_funcs *alloc_gensio_selector(swig_cb *log_handler)
{
    struct selector_s *sel;
    struct gensio_os_funcs *o;
    struct os_funcs_data *odata;
    int err;
    int wake_sig;
#ifdef USE_POSIX_THREADS
    struct sigaction act;

    wake_sig = SIGUSR1;
    act.sa_handler = gensio_thread_sighandler;
    sigemptyset(&act.sa_mask);
    act.sa_flags = 0;
    err = sigaction(SIGUSR1, &act, NULL);
    if (err) {
	fprintf(stderr, "Unable to setup wake signal: %s, giving up\n",
		strerror(errno));
	exit(1);
    }

    err = sel_alloc_selector_thread(&sel, SIGUSR1,
				    gensio_alloc_lock, gensio_free_lock,
				    gensio_lock, gensio_unlock, NULL);
#else
    err = sel_alloc_selector_nothread(&sel);
#endif
    if (err) {
	fprintf(stderr, "Unable to allocate selector: %s, giving up\n",
		strerror(err));
	exit(1);
    }

    odata = malloc(sizeof(*odata));
    odata->refcount = 1;
#ifdef USE_POSIX_THREADS
    pthread_mutex_init(&odata->lock, NULL);
#endif

    o = gensio_selector_alloc(sel, wake_sig);
    if (!o) {
	fprintf(stderr, "Unable to allocate gensio os funcs, giving up\n");
	exit(1);
    }
    odata->sel = sel;
    o->other_data = odata;
    odata->log_handler = ref_swig_cb(log_handler, gensio_log);
    o->vlog = gensio_do_vlog;

    return o;
}

%}

%init %{
#ifdef USE_POSIX_THREADS
    {
	int err;

	err = pthread_key_create(&gensio_thread_key, gensio_key_del);
	if (err) {
	    fprintf(stderr, "Error creating gensio thread key: %s, giving up\n",
		    strerror(err));
	    exit(1);
	}
    }
#endif
    gensio_swig_init_lang();
%}

%include <typemaps.i>
%include <exception.i>

%include "gensio_python.i"

%nodefaultctor sergensio;
%nodefaultctor gensio_os_funcs;
struct gensio { };
struct sergensio { };
struct gensio_accepter { };
struct gensio_os_funcs { };
struct waiter { };

%extend gensio_os_funcs {
    ~gensio_os_funcs() {
	check_os_funcs_free(self);
    }

    void service() {
	self->service(self, NULL);
    }

    int service(int timeout) {
	struct timeval tv = { timeout / 1000, timeout % 1000 };

	return self->service(self, &tv);
    }
}

%constant int GE_NOTSUP = GE_NOTSUP;
%constant int GE_KEYINVALID = GE_KEYINVALID;

%constant int GENSIO_CONTROL_DEPTH_ALL = GENSIO_CONTROL_DEPTH_ALL;
%constant int GENSIO_CONTROL_DEPTH_FIRST = GENSIO_CONTROL_DEPTH_FIRST;
%constant int GENSIO_CONTROL_NODELAY = GENSIO_CONTROL_NODELAY;
%constant int GENSIO_CONTROL_STREAMS = GENSIO_CONTROL_STREAMS;
%constant int GENSIO_CONTROL_SEND_BREAK = GENSIO_CONTROL_SEND_BREAK;
%constant int GENSIO_CONTROL_GET_PEER_CERT_NAME =
    GENSIO_CONTROL_GET_PEER_CERT_NAME;
%constant int GENSIO_CONTROL_CERT_AUTH = GENSIO_CONTROL_CERT_AUTH;
%constant int GENSIO_CONTROL_USERNAME = GENSIO_CONTROL_USERNAME;
%constant int GENSIO_CONTROL_SERVICE = GENSIO_CONTROL_SERVICE;
%constant int GENSIO_CONTROL_CERT = GENSIO_CONTROL_CERT;
%constant int GENSIO_CONTROL_CERT_FINGERPRINT = GENSIO_CONTROL_CERT_FINGERPRINT;

%extend gensio {
    gensio(struct gensio_os_funcs *o, char *str, swig_cb *handler) {
	int rv;
	struct gensio_data *data;
	struct gensio *io = NULL;

	data = alloc_gensio_data(o, handler);
	if (!data)
	    return NULL;

	rv = str_to_gensio(str, o, gensio_child_event, data, &io);
	if (rv) {
	    free_gensio_data(data);
	    err_handle("gensio alloc", rv);
	}
	return io;
    }

    ~gensio()
    {
	struct gensio_data *data = gensio_get_user_data(self);

	if (data->tmpval)
	    return;
	deref_gensio_data(data, self);
    }

    void set_cbs(swig_cb *handler) {
	struct gensio_data *data = gensio_get_user_data(self);

	if (data->handler_val)
	    deref_swig_cb_val(data->handler_val);
	data->handler_val = ref_swig_cb(handler, read_callback);
    }

    %rename (remote_id) remote_idt;
    int remote_idt() {
	int remid;

	err_handle("remote_id", gensio_remote_id(self, &remid));
	return remid;
    }

    %rename(open) opent;
    void opent(swig_cb *done) {
	swig_cb_val *done_val = NULL;
	void (*open_done)(struct gensio *io, int err, void *cb_data) = NULL;
	int rv;

	if (!nil_swig_cb(done)) {
	    open_done = gensio_open_done;
	    done_val = ref_swig_cb(done, open_done);
	}
	rv = gensio_open(self, open_done, done_val);
	if (rv && done_val)
	    deref_swig_cb_val(done_val);

	err_handle("open", rv);
    }

    %rename(open_s) open_st;
    void open_st() {
	err_handle("open_s", gensio_open_s(self));
    }

    %newobject open_channelt;
    %rename(open_channel) open_channelt;
    struct gensio *open_channelt(const char * const *args,
				 swig_cb *handler, swig_cb *done) {
	struct gensio_data *olddata = gensio_get_user_data(self);
	swig_cb_val *done_val = NULL;
	void (*open_done)(struct gensio *io, int err, void *cb_data) = NULL;
	int rv = 0;
	struct gensio_data *data;
	struct gensio *io = NULL;

	data = alloc_gensio_data(olddata->o, handler);
	if (!data) {
	    err_handle("gensio open channel", rv);
	    return NULL;
	}

	if (!nil_swig_cb(done)) {
	    open_done = gensio_open_done;
	    done_val = ref_swig_cb(done, open_done);
	}
	rv = gensio_open_channel(self, args, gensio_child_event, data,
				 open_done, done_val, &io);
	if (rv) {
	    if (done_val)
		deref_swig_cb_val(done_val);
	    free_gensio_data(data);
	    err_handle("open_channel", rv);
	}

	return io;
    }

    %newobject open_channel_st;
    %rename(open_channel_s) open_channel_st;
    struct gensio *open_channel_st(const char * const *args, swig_cb *handler) {
	struct gensio_data *olddata = gensio_get_user_data(self);
	struct gensio_os_funcs *o = olddata->o;
	int rv = 0;
	struct gensio_data *data;
	struct gensio *io = NULL;

	data = alloc_gensio_data(o, handler);
	if (!data) {
	    err_handle("gensio alloc", rv);
	    return NULL;
	}

	rv = gensio_open_channel_s(self, args, gensio_child_event, data, &io);
	if (rv) {
	    free_gensio_data(data);
	    err_handle("open_channel", rv);
	}

	return io;
    }

    %rename(get_type) get_typet;
    const char *get_typet(unsigned int depth) {
	return gensio_get_type(self, depth);
    }

    %rename(close) closet;
    void closet(swig_cb *done) {
	swig_cb_val *done_val = NULL;
	void (*close_done)(struct gensio *io, void *cb_data) = NULL;
	int rv;

	if (!nil_swig_cb(done)) {
	    close_done = gensio_close_done;
	    done_val = ref_swig_cb(done, close_done);
	}
	rv = gensio_close(self, close_done, done_val);
	if (rv && done_val)
	    deref_swig_cb_val(done_val);

	err_handle("close", rv);
    }

    %rename(close_s) close_st;
    void close_st() {
	err_handle("close_s", gensio_close_s(self));
    }

    %rename(write) writet;
    unsigned int writet(char *bytestr, my_ssize_t len,
			const char *const *auxdata) {
	gensiods wr = 0;
	int rv;

	rv = gensio_write(self, &wr, bytestr, len, auxdata);
	err_handle("write", rv);
	return wr;
    }

    void read_cb_enable(bool enable) {
	gensio_set_read_callback_enable(self, enable);
    }

    void write_cb_enable(bool enable) {
	gensio_set_write_callback_enable(self, enable);
    }

    %rename(control) controlt;
    %newobject controlt;
    char *controlt(int depth, bool get, int option, char *controldata) {
	int rv;
	char *data = NULL;

	if (get) {
	    gensiods len = 0, slen = 1;

	    if (controldata)
		slen = strlen(controldata) + 1;

	    /* Pass in a zero length to get the actual length. */
	    rv = gensio_control(self, depth, get, option, controldata, &len);
	    if (rv)
		goto out;
	    len += 1;
	    /* Allocate the larger of strlen(controldata) and len) */
	    if (slen > len)
		data = malloc(slen);
	    else
		data = malloc(len);
	    if (!data) {
		rv = GE_NOMEM;
		goto out;
	    }
	    if (controldata)
		memcpy(data, controldata, slen);
	    else
		data[0] = '\0';
	    rv = gensio_control(self, depth, get, option, data, &len);
	    if (rv) {
		free(data);
		data = NULL;
	    }
	out:
	    if (rv == GE_NOTFOUND) /* Return None for ENOENT. */
		return NULL;
	} else {
	    rv = gensio_control(self, depth, get, option, controldata, NULL);
	}

	err_handle("control", rv);
	return data;
    }

    %rename(is_client) is_clientt;
    bool is_clientt() {
	return gensio_is_client(self);
    }

    %rename(is_packet) is_packett;
    bool is_packett() {
	return gensio_is_packet(self);
    }

    %rename(is_reliable) is_reliablet;
    bool is_reliablet() {
	return gensio_is_reliable(self);
    }

    %rename(is_authenticated) is_authenticated;
    bool is_authenticatedt() {
	return gensio_is_authenticated(self);
    }

    %rename(is_encrypted) is_encryptedt;
    bool is_encryptedt() {
	return gensio_is_encrypted(self);
    }

    %newobject cast_to_sergensio;
    struct sergensio *cast_to_sergensio() {
	struct gensio_data *data = gensio_get_user_data(self);
	struct sergensio *sio = gensio_to_sergensio(self);

	if (!sio)
	    cast_error("sergensio", "gensio");
	ref_gensio_data(data);
	return sio;
    }
}

%define sgensio_entry(name)
    void sg_##name(int name, swig_cb *h) {
	struct sergensio_cbdata *cbdata = NULL;
	int rv;

	if (!nil_swig_cb(h)) {
	    cbdata = sergensio_cbdata(name, h);
	    if (!cbdata) {
		oom_err();
		return;
	    }
	    rv = sergensio_##name(self, name, sergensio_cb, cbdata);
	} else {
	    rv = sergensio_##name(self, name, NULL, NULL);
	}

	if (rv && cbdata)
	    cleanup_sergensio_cbdata(cbdata);
	ser_err_handle("sg_"stringify(name), rv);
    }

    int sg_##name##_s(int name) {
	struct gensio *io = sergensio_to_gensio(self);
	struct gensio_data *data = gensio_get_user_data(io);
	struct sergensio_b *b = NULL;
	int rv;

	rv = sergensio_b_alloc(self, data->o, &b);
	if (!rv)
	    rv = sergensio_##name##_b(b, &name);
	if (rv)
	    ser_err_handle("sg_"stringify(name)"_s", rv);
	if (b)
	    sergensio_b_free(b);
	return name;
    }
%enddef

%constant int SERGENSIO_PARITY_NONE = SERGENSIO_PARITY_NONE;
%constant int SERGENSIO_PARITY_ODD = SERGENSIO_PARITY_ODD;
%constant int SERGENSIO_PARITY_EVEN = SERGENSIO_PARITY_EVEN;
%constant int SERGENSIO_PARITY_MARK = SERGENSIO_PARITY_MARK;
%constant int SERGENSIO_PARITY_SPACE = SERGENSIO_PARITY_SPACE;

%constant int SERGENSIO_FLOWCONTROL_NONE = SERGENSIO_FLOWCONTROL_NONE;
%constant int SERGENSIO_FLOWCONTROL_XON_XOFF = SERGENSIO_FLOWCONTROL_XON_XOFF;
%constant int SERGENSIO_FLOWCONTROL_RTS_CTS = SERGENSIO_FLOWCONTROL_RTS_CTS;
%constant int SERGENSIO_FLOWCONTROL_DCD = SERGENSIO_FLOWCONTROL_DCD;
%constant int SERGENSIO_FLOWCONTROL_DTR = SERGENSIO_FLOWCONTROL_DTR;
%constant int SERGENSIO_FLOWCONTROL_DSR = SERGENSIO_FLOWCONTROL_DSR;

%constant int SERGENSIO_BREAK_ON = SERGENSIO_BREAK_ON;
%constant int SERGENSIO_BREAK_OFF = SERGENSIO_BREAK_OFF;

%constant int SERGENSIO_DTR_ON = SERGENSIO_DTR_ON;
%constant int SERGENSIO_DTR_OFF = SERGENSIO_DTR_OFF;

%constant int SERGENSIO_RTS_ON = SERGENSIO_RTS_ON;
%constant int SERGENSIO_RTS_OFF = SERGENSIO_RTS_OFF;

%constant int SERGENSIO_LINESTATE_DATA_READY = SERGENSIO_LINESTATE_DATA_READY;
%constant int SERGENSIO_LINESTATE_OVERRUN_ERR = SERGENSIO_LINESTATE_OVERRUN_ERR;
%constant int SERGENSIO_LINESTATE_PARITY_ERR = SERGENSIO_LINESTATE_PARITY_ERR;
%constant int SERGENSIO_LINESTATE_FRAMING_ERR = SERGENSIO_LINESTATE_FRAMING_ERR;
%constant int SERGENSIO_LINESTATE_BREAK = SERGENSIO_LINESTATE_BREAK;
%constant int SERGENSIO_LINESTATE_XMIT_HOLD_EMPTY =
	SERGENSIO_LINESTATE_XMIT_HOLD_EMPTY;
%constant int SERGENSIO_LINESTATE_XMIT_SHIFT_EMPTY =
	SERGENSIO_LINESTATE_XMIT_SHIFT_EMPTY;
%constant int SERGENSIO_LINESTATE_TIMEOUT_ERR = SERGENSIO_LINESTATE_TIMEOUT_ERR;

%constant int SERGENSIO_MODEMSTATE_CTS_CHANGED = SERGENSIO_MODEMSTATE_CTS_CHANGED;
%constant int SERGENSIO_MODEMSTATE_DSR_CHANGED = SERGENSIO_MODEMSTATE_DSR_CHANGED;
%constant int SERGENSIO_MODEMSTATE_RI_CHANGED = SERGENSIO_MODEMSTATE_RI_CHANGED;
%constant int SERGENSIO_MODEMSTATE_CD_CHANGED = SERGENSIO_MODEMSTATE_CD_CHANGED;
%constant int SERGENSIO_MODEMSTATE_CTS = SERGENSIO_MODEMSTATE_CTS;
%constant int SERGENSIO_MODEMSTATE_DSR = SERGENSIO_MODEMSTATE_DSR;
%constant int SERGENSIO_MODEMSTATE_RI = SERGENSIO_MODEMSTATE_RI;
%constant int SERGENSIO_MODEMSTATE_CD = SERGENSIO_MODEMSTATE_CD;

%constant int SERGIO_FLUSH_RCV_BUFFER = SERGIO_FLUSH_RCV_BUFFER;
%constant int SERGIO_FLUSH_XMIT_BUFFER = SERGIO_FLUSH_XMIT_BUFFER;
%constant int SERGIO_FLUSH_RCV_XMIT_BUFFERS = SERGIO_FLUSH_RCV_XMIT_BUFFERS;


%nodefaultctor sergensio;
%extend sergensio {
    ~sergensio()
    {
	struct gensio *io = sergensio_to_gensio(self);
	struct gensio_data *data = gensio_get_user_data(io);

	deref_gensio_data(data, io);
    }

    %newobject cast_to_gensio;
    struct gensio *cast_to_gensio() {
	struct gensio *io = sergensio_to_gensio(self);
	struct gensio_data *data = gensio_get_user_data(io);

	ref_gensio_data(data);
	return io;
    }

    /* Standard baud rates. */
    sgensio_entry(baud);

    /* 5, 6, 7, or 8 bits. */
    sgensio_entry(datasize);

    /* SERGENSIO_PARITY_ entries */
    sgensio_entry(parity);

    /* 1 or 2 */
    sgensio_entry(stopbits);

    /* SERGENSIO_FLOWCONTROL_ entries */
    sgensio_entry(flowcontrol);

    /* SERGENSIO_FLOWCONTROL_ entries for iflowcontrol */
    sgensio_entry(iflowcontrol);

    /* SERGENSIO_BREAK_ entries */
    sgensio_entry(sbreak);

    /* SERGENSIO_DTR_ entries */
    sgensio_entry(dtr);

    /* SERGENSIO_RTS_ entries */
    sgensio_entry(rts);

    int sg_modemstate(unsigned int modemstate) {
	return sergensio_modemstate(self, modemstate);
    }

    int sg_linestate(unsigned int linestate) {
	return sergensio_linestate(self, linestate);
    }

    int sg_flowcontrol_state(bool val) {
	return sergensio_flowcontrol_state(self, val);
    }

    int sg_flush(unsigned int val) {
	return sergensio_flush(self, val);
    }
}

%extend gensio_accepter {
    gensio_accepter(struct gensio_os_funcs *o, char *str, swig_cb *handler) {
	struct gensio_data *data;
	struct gensio_accepter *acc = NULL;
	int rv;

	data = alloc_gensio_data(o, handler);
	if (!data)
	    return NULL;

	rv = str_to_gensio_accepter(str, o, gensio_acc_child_event, data, &acc);
	if (rv) {
	    free_gensio_data(data);
	    err_handle("gensio_accepter constructor", rv);
	}

	return acc;
    }

    ~gensio_accepter()
    {
	struct gensio_data *data = gensio_acc_get_user_data(self);

	deref_gensio_accepter_data(data, self);
    }

    %newobject str_to_gensio;
    struct gensio *str_to_gensio(char *str, swig_cb *handler) {
	struct gensio_data *olddata = gensio_acc_get_user_data(self);
	int rv;
	struct gensio_data *data;
	struct gensio *io;

	data = alloc_gensio_data(olddata->o, handler);
	if (!data)
	    return NULL;

	rv = gensio_acc_str_to_gensio(self, str, gensio_child_event, data,
				      &io);
	if (rv) {
	    free_gensio_data(data);
	    err_handle("str to gensio", rv);
	}

	return io;
    }

    void startup() {
	int rv = gensio_acc_startup(self);

	err_handle("startup", rv);
    }

    void shutdown(swig_cb *done) {
	swig_cb_val *done_val = NULL;
	int rv;

	if (!nil_swig_cb(done))
	    done_val = ref_swig_cb(done, shutdown);
	rv = gensio_acc_shutdown(self, gensio_acc_shutdown_done, done_val);
	if (rv && done_val)
	    deref_swig_cb_val(done_val);

	err_handle("shutdown", rv);
    }

    void shutdown_s() {
	int rv = gensio_acc_shutdown_s(self);

	err_handle("shutdown_s", rv);
    }

    void disable() {
	gensio_acc_disable(self);
    }

    %newobject control;
    char *control(int depth, bool get, int option, char *controldata) {
	int rv;
	char *data = NULL;

	if (get) {
	    gensiods len = 0, slen = strlen(controldata) + 1;

	    /* Pass in a zero length to get the actual length. */
	    rv = gensio_acc_control(self, depth, get, option, controldata,
				    &len);
	    if (rv)
		goto out;
	    len += 1;
	    /* Allocate the larger of strlen(controldata) and len) */
	    if (slen > len)
		data = malloc(slen);
	    else
		data = malloc(len);
	    if (!data) {
		rv = GE_NOMEM;
		goto out;
	    }
	    memcpy(data, controldata, slen);
	    rv = gensio_acc_control(self, depth, get, option, data, &len);
	    if (rv) {
		free(data);
		data = NULL;
	    }
	} else {
	    rv = gensio_acc_control(self, depth, get, option, controldata,
				    NULL);
	}

    out:
	err_handle("control", rv);
	return data;
    }

    bool is_packet() {
	return gensio_acc_is_packet(self);
    }

    bool is_reliable() {
	return gensio_acc_is_reliable(self);
    }

}

%extend waiter {
    waiter(struct gensio_os_funcs *o) {
	struct waiter *w = malloc(sizeof(*w));

	if (w) {
	    w->o = o;
	    w->waiter = o->alloc_waiter(o);
	    if (!w->waiter) {
		free(w);
		w = NULL;
		err_handle("waiter", GE_NOMEM);
	    } else {
		os_funcs_ref(o);
	    }
	} else {
	    err_handle("waiter", GE_NOMEM);
	}

	return w;
    }

    ~waiter() {
	self->o->free_waiter(self->waiter);
	check_os_funcs_free(self->o);
	free(self);
    }

    int wait_timeout(unsigned int count, int timeout) {
	struct timeval tv = { timeout / 1000, timeout % 1000 };

	return gensio_do_wait(self, count, &tv);
    }

    void wait(unsigned int count) {
	gensio_do_wait(self, count, NULL);
    }

    void wake() {
	self->o->wake(self->waiter);
    }
}

/* Get a bunch of random bytes. */
void get_random_bytes(char **rbuffer, size_t *rbuffer_len,
		      int size_to_allocate);

%newobject alloc_gensio_selector;
struct gensio_os_funcs *alloc_gensio_selector(swig_cb *log_handler);

%constant int GENSIO_LOG_FATAL = GENSIO_LOG_FATAL;
%constant int GENSIO_LOG_ERR = GENSIO_LOG_ERR;
%constant int GENSIO_LOG_WARNING = GENSIO_LOG_WARNING;
%constant int GENSIO_LOG_INFO = GENSIO_LOG_INFO;
%constant int GENSIO_LOG_DEBUG = GENSIO_LOG_DEBUG;
%constant int GENSIO_LOG_MASK_ALL = GENSIO_LOG_MASK_ALL;

void gensio_set_log_mask(unsigned int mask);

unsigned int gensio_get_log_mask(void);
