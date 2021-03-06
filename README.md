elogx
=====
erlang日志服务拓展(erlang logger extension)


### 1. elogx_pid_h
用途：远程注入到logger中，然后实时获取远程的日志内容

```
$ rebar3 compile

$ erl -config config/sys-pid -pa `rebar3 path`
1> application:start(elogx).
ok
2> elogx_pid_h:add_pid(elogx_pid_h,self()).
ok
3> erlang:whereis(elogx_pid_h_elogx_pid_h).
<0.90.0>
4> logger:info("abc").
ok
5> flush().
Shell got {log,<0.90.0>,<<"2021-01-06T16:52:56.798546+08:00 info: abc\n">>}
ok
```


### 2. elogx_cnt_h
用途：每个日志文件写入固定的日志数量
配置项目：

| name | type | note |
| --- | --- | --- |
| file | string | 文件名称|
| modes |`[atom()]`|  |
| max_no_files | int | |
| compress_on_rotate | boolean | 
| file_check | int |
| max_no_count |int | 每个文件最多写入多少条日志 |


