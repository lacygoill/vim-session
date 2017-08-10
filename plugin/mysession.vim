" Autocmd {{{1

augroup my_session
    au!
    au StdInReadPost * let s:read_stdin = 1
    au VimEnter * nested if s:safe_to_load_session() | SLoad | endif
    "             │
    "             └─ necessary to source ftplugins (trigger autocmds listening to bufread event?)

    " NOTE: The next autocmd serves 2 purposes:{{{
    "
    "     1. automatically save the current session, as soon as `g:my_session`
    "        pops into existence
    "
    "     2. update the session file frequently, and as long as `g:my_session` exists
    "        IOW, track the session
    "
    " We need the autocmd to be in `plugin/`.
    " Otherwise, if we move it inside `autoload/`, it would resume tracking
    " a session only if it has been loaded through `:STrack`, not through
    " a simple `:source`. It would give this:
    "
    "         :STrack …
    "         → call mysession#handle_session()
    "         → source autoload/mysession.vim
    "         → install autocmd
    "         → resume tracking
    "
    " The tracking should resume no matter how we sourced a session file.
"}}}

    "                            ┌─ if sth goes wrong, the function returns the string:
    "                            │       'echoerr '.string(v:exception)
    "                            │
    "                            │  we need to execute this string
    "                            │
    au BufWinEnter,VimLeavePre * exe mysession#track()
    "  │
    "  └─ We don't want the session to be saved only when we quit Vim,
    "     because Vim could exit abnormally.
    "
    "     NOTE:
    "     Contrary to `BufEnter`, `BufWinEnter` is NOT fired for `:split`
    "     (without arguments), nor for `:split file`, file being already
    "     displayed in a window.
    "
    "     But most of the time, Vim won't quit abnormally, and the last saved
    "     state of our session will be performed when VimLeavePre is fired.
    "     So, `VimLeavePre` will have the final say most of the time.

    au TabClosed * call timer_start(0, {-> execute('exe mysession#track()')})
    " We also save whenever we close a tabpage, because we don't want
    " a closed tabpage to be restored while we switch back and forth between
    " 2 sessions with `:SLoad`.
    " But, we can't save the session immediately, because for some reason, Vim
    " would only save the last tabpage (or the current one?). So, we delay the
    " saving.
augroup END

" Functions "{{{1
" My_session_status {{{2

fu! My_session_status() abort

    " From the perspective of sessions, Vim can be in 3 states:
    "
    "         - no session has been loaded or saved
    "
    "         - a session has been loaded or saved, but isn't tracked by our plugin
    "
    "           NOTE:
    "           It happens when `g:my_session` is empty, but not `v:this_session`.
    "           The reverse can NOT happen:
    "                   `v:this_session` is empty, but not `g:this_session`
    "
    "           … because if `g:my_session` isn't empty, it means
    "           a session has been loaded/saved, and therefore
    "           `v:this_session` must contain the name of the file which
    "           was used.
    "
    "           IOW, a session CAN be loaded/saved without our plugin
    "           knowing it. But, a session can NOT be loaded/saved
    "           without Vim knowing it.
    "
    "         - a session is being tracked by our plugin

    " We create the variable `state` whose value, 0, 1 or 2, stands for
    " the state of Vim.
    "
    "           ┌─ a session has been loaded/saved
    "           │                        ┌─ we're in a session tracked by our plugin
    "           │                        │
    let state = !empty(v:this_session) + exists('g:my_session')
    "                  │
    "                  └─ stores the path to the last file which has been used
    "                     to load/save a session;
    "                     if no session has been saved/loaded, it's empty

    " return:
    "
    "         - `∞`     if a session is being tracked
    "         - `S`     if a session has been loaded/saved, but isn't tracked
    "         - nothing if no session has been loaded/saved
    "
    " The returned value is displayed in the statusline.

    return [ '', '[S]', '[∞]' ][state]
endfu

fu! s:safe_to_load_session() abort "{{{2
    "      ┌─ Vim should be started with NO files to edit.
    "      │  If there are files to edit we don't want their buffers to be
    "      │  immediately lost by a restored session.
    "      │
    "      │          ┌─ a session shouldn't be loaded when we use Vim in a pipeline
    "      │          │
    return !argc() && !get(s:, 'read_stdin', 0) && len(systemlist('pgrep vim')) < 2
    "                                              │
    "                                              └─ if a Vim instance is already running
    "                                              it's possible that some files of the session are
    "                                              already loaded in that instance
    "                                              loading them in a 2nd instance could raise errors (E325)
endfu

" track {{{2

" This function saves the current session, iff `g:my_session` exists.
" In the session file, it adds the line:
"         let g:my_session = v:this_session
"
" … so that the next time we load the session, the plugin knows that it must
" track it automatically.
"
" It needs to be public to be callable from `handle_session()`.
" If we moved the latter here, we could make `track()` script-local.
" We don't, to lazy-load as much code as we can.

fu! mysession#track() abort
    if exists('g:SessionLoad')
        " `g:SessionLoad` exists temporarily while a session is loading.
        " See: :h SessionLoad-variable
        "
        " Suppose we source a session file:
        "
        "       :so file
        "
        " During the restoration process, `BufWinEnter` would be fired several
        " times. Every time, the current function would try to update the session
        " file. This would overwrite the latter, while it's being used to restore
        " the session. Don't do that.
        "
        " Our session file will be updated next time (`BufWinEnter`, `TabClosed`,
        " `VimLeavePre`).

        return ''
    endif

    " update the session  iff / as soon as  this variable exists
    if exists('g:my_session')
        try
            "             ┌─ overwrite any existing file
            "             │
            exe 'mksession! '.fnameescape(g:my_session)

            "   ┌─ lines of our session file
            "   │
            let body = readfile(g:my_session)

            " add the Ex command:
            "         let g:my_session = v:this_session
            "
            " … just before the last 3 commands:
            "
            "         doautoall SessionLoadPost
            "         unlet SessionLoad
            "         vim: set ft=vim : (modeline)
            call insert(body, 'let g:my_session = v:this_session', -3)
            call writefile(body, g:my_session)

        catch
            " If sth goes wrong now, it will probably go wrong next time.
            " We don't want to go on trying to save a session, if `default.vim`
            " isn't writable for example.
            unlet! g:my_session

            " update all status lines, to remove the `[∞]` item
            redrawstatus!

            return 'echoerr '.string(v:exception)
        endtry
    endif
    return ''
endfu

" IFF {{{1

" NOTE:
"
"                      ┌ B
" ┌────────────────────┤
" It will be overwritten IF it looks like a session file.
"                           └──────────────────────────┤
"                                                      └ A
"
" rewritten formally:
"
"     A ⇒ B :  IF it looks like a session file, it will be overwritten
"
"
"                      ┌ B
" ┌────────────────────┤
" It will be overwritten, IF AND ONLY IF it looks like a session file.
"                                        └──────────────────────────┤
"                                                                   └ A
"
" rewritten formally:
"
"      A  ⇒  B  : same as before
"
" +    B  ⇒  A  : IF it is overwritten, it looks like a session file
" OR  ¬A  ⇒ ¬B  : IF it does NOT look like a session file, it will NOT be overwritten
"
" Summary:
" “iff“ = you can read in whatever direction, positively or NEGATIVELY
"         it's ALWAYS true
"
" “iff“ is frequently used to mean `if B then A` + `if ¬B then ¬A`.
"                                                   ├───────────┘
"             this whole part is added by the 2nd f ┘

" Interface {{{1

" NOTE: Why `exe mysession#handle_session()` {{{
" and why `exe mysession#track()`?
"
" If an error occurs in a function, we'll get an error such as:
"
"         Error detected while processing function mysession#track:
"         line   19:
"         Vim:E492: Not an editor command:             abcd
"
" We want our `:STrack` command, and our autocmd, to produce a message
" similar to a regular Ex command. We don't want the detail of the implementation
" to leak.
"
" By using `exe function()`, we can get an error message such as:
"
"         Error detected while processing BufWinEnter Auto commands for "*":
"         Vim:E492: Not an editor command:             abcd
"
" How does it work?
" When an error may occur, we capture it and convert it into a string:
"
"     try
"         …
"     catch
"         return 'echoerr '.string(v:exception)
"     endtry
"
" We execute this string in the context of `:STrack`, or of the autocmd.
" Basically, the try conditional + `exe function()` is a mechanism which
" allows us to choose the context in which an error may occur.
" Note, however, that in this case, it prevents our `:WTF` command from capturing
" the error, because it will happen outside of a function.
"
" "}}}

com! -bar -bang -complete=file -nargs=?  STrack    exe mysession#handle_session(<bang>0, <q-args>)
com! -bar       -complete=customlist,mysession#suggest_sessions -nargs=?  SLoad  call mysession#restore(<q-args>)

" Usage {{{1

"     :STrack file
"
" Invoke `:mksession` on `file`, iff `file`:
"
"     • doesn't exist
"     • is empty
"     • looks like a session file (according to its name or its contents)
"
" Update the file whenever `BufWinEnter`, `TabClosed` or `VimLeavePre` is fired.
"
"
"     :STrack dir
"
" Invoke `:STrack` on `dir/default.vim`.
"
"
"     :STrack
"
" If the tracking of a session is running:  pause it
" If the tracking of a session is paused:   resume it
" If no session is being tracked, start tracking the current session in
" ~/.vim/session/default.vim
"
"
"     :STrack!
"
" If no session is being tracked, begin the tracking.
" If the tracking of a session is running:  cancel it and remove the session
" file.
"
"
" Loading a session created with `:STrack` automatically resumes updates
" to that file.
