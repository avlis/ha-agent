import os
import signal
import sys
import operator
from time import sleep
import socket
import threading


#################
#   GLOBALS
#################

STATUS = ''
status_lock = threading.Lock()

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
r = None #placeholder for refreshing thread object
keep_refreshing = True


#################
#   defs
#################

def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, flush=True, **kwargs)

def refresh_stats(refresh_interval, proc_prefix, cpu_weight, iow_weight, mem_weight):
    global STATUS
    global keep_refreshing

    stat_path='{0}/stat'.format(proc_prefix)
    meminfo_path='{0}/meminfo'.format(proc_prefix)

    total_weight=cpu_weight+iow_weight+mem_weight

    eprint ('starting refresh_stats thread, with interval={0}, proc fs @ {1}'.format(refresh_interval, proc_prefix))

    while keep_refreshing:
        cpu_info1 = [int(x) for x in open(stat_path,'r').readline()[:-1].split(' ')[2:]]
        sleep(refresh_interval)

        mem_info = dict(
            (i.split()[0].rstrip(':'), float(i.split()[1]))
            for i in open(meminfo_path,'r').readlines()
        )

        mem_free=(mem_info['MemAvailable']/mem_info['MemTotal'])

        cpu_info2 = [float(x) for x in open(stat_path,'r').readline()[:-1].split(' ')[2:]]
        cpu_result=list(map(operator.sub,cpu_info2,cpu_info1))
        #eprint(cpu_result)
        cpu_total = sum(cpu_result)
        cpu_free = float(cpu_result[3]/cpu_total)
        cpu_iow = 1-float(cpu_result[4]/cpu_total)

        final_stats = (((cpu_free * cpu_weight) + (cpu_iow * iow_weight) + (mem_free * mem_weight)) / total_weight )*100


        try:
            file_status = open('/etc/ha-agent.status','r').readline()[:-1]
        except:
            file_status = ''

        #eprint('cpu {0:.3f}, iow {1:.3f}, mem {2:.3f}, final {3:.0f}%, file [{4}]'.format(cpu_free, cpu_iow, mem_free, final_stats, file_status))

        status_lock.acquire()
        STATUS = '{0:.0f}% {1}\n'.format(final_stats, file_status)
        status_lock.release()

def respond(c,addr):
    try:
        status_lock.acquire()
        #eprint('sending [{0}] to {1}:{2}'.format(STATUS,addr[0],addr[1]))
        c.send(str.encode(STATUS))
        status_lock.release()
        c.close()
    except:
        eprint('error replying to [{0}:{1}]'.format(addr[0],addr[1]))
    finally:
        if status_lock.locked:
            status_lock.release()

def sig_handler(signum, frame):
    global s
    global r
    global keep_refreshing
    eprint('signal received, closing socket and stopping refresh stats thread...')
    keep_refreshing = False
    try:
        s.close()
        r.join()
    finally:
        eprint('cleanup finished. bye!')
    sys.exit()

def Main():
    global s
    global r

    port = int(os.getenv('PORT',7777))
    refresh_interval = int(os.getenv('REFRESH_INTERVAL',7))
    proc_prefix = os.getenv('PROC_PREFIX','/proc/')
    host = os.getenv('HOST','')

    cpu_weight = int(os.getenv('CPU_WEIGHT',1))
    iow_weight = int(os.getenv('IOW_WEIGHT',1))
    mem_weight = int(os.getenv('MEM_WEIGHT',1))

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    r=threading.Thread(target=refresh_stats,args=(refresh_interval, proc_prefix, cpu_weight, iow_weight, mem_weight))
    r.start()

    s.bind((host, port))
    eprint('socket binded to port {0} on host [{1}]'.format(port,host))

    # put the socket into listening mode
    s.listen(5)
    eprint('socket is listening')

    # a forever loop until client wants to exit
    try:
        while True:
            # establish connection with client
            c, addr = s.accept()

            #eprint('Connected to :', addr[0], ':', addr[1])
            threading.Thread(target=respond, args=(c,addr)).start()
    except:
        sig_handler(signal.SIGTERM, None)

if __name__ == '__main__':
    Main()
