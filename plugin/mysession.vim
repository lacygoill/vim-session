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

" Usage {{{1

"     :SessionSave file
"
" Invoke `:mksession` on `file`, iff `file`:
"
"     • doesn't exist
"     • is empty
"     • looks like a session file
"
" Update the file whenever `BufWinEnter` or `VimLeavePre` is fired.
"
"
"     :SessionSave dir
"
" Invoke `:SessionSave` on `dir/Session.vim`.
"
"
"     :SessionSave
"
" If the tracking of a session is running:  pause it
" If the tracking of a session is paused:   resume it
" If no session is being tracked, start tracking the current session in
" ~/.vim/session/Session.vim
"
"
"     :SessionSave!
"
" If no session is being tracked, begin the tracking.
" If the tracking of a session is running:  cancel it and remove the session
" file.
"
"
" Loading a session created with `:SessionSave` automatically resumes updates
" to that file.

" Interface {{{1

" NOTE: Why `exe mysession#manual_save()` {{{
" and why `exe mysession#auto_save()`?
"
" If an error occurs in a function, we'll get an error such as:
"
"         Error detected while processing function mysession#auto_save:
"         line   19:
"         Vim:E492: Not an editor command:             abcd
"
" We want our `:SessionSave` command, and our autocmd, to produce a message
" similar to a regular Ex command. We don't want to see the detail of the
" implementation leaking.
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
" We execute this string in the context of `:SessionSave`, or of the autocmd.
" Basically, the try conditional + `exe function()` is a mechanism which
" allows us to choose the context in which an error may occur.
" Note, however, that in this case, it prevents our `:WTF` command from capturing
" the error, because it will happen outside of a function.
"
" "}}}

com! -bar -bang -complete=file -nargs=?  SessionSave     exe mysession#manual_save(<bang>0, <q-args>)
com! -bar       -complete=file -nargs=?  SessionRestore  call mysession#restore(<q-args>)

" Autocmd {{{1

augroup my_session
    au!
    au StdInReadPost * let s:read_stdin = 1

    "                       ┌─ if Vim was started with files to edit, we don't
    "                       │  want their buffers to be immediately lost by
    "                       │  a restored session
    "                       │
    au VimEnter * nested if !argc() && !get(s:, 'read_stdin', 0) | SessionRestore | endif
    "             │
    "             └─ necessary to source ftplugins
    "                (trigger autocmds listening to bufread event?)

    " The next autocmd serves 2 purposes:
    "
    "     1. automatically save the current session, as soon as `g:my_session`
    "        pops into existence
    "
    "     2. update the session file frequently, and as long as `g:my_session` exists
    "        IOW, track the session
    "
    " We need the autocmd to be in `plugin/`.
    " Otherwise, if we move it inside `autoload/`, it wouldn't resume tracking
    " a restored session until `:SessionSave` is invoked.
    " It would give this:
    "
    "         :SessionSave …
    "         → call mysession#manual_save()
    "         → source autoload/mysession.vim
    "         → install autocmd
    "         → resume tracking
    "
    " We want the plugin to resume tracking, even if we manually load a previously
    " tracked session:    :so ~/.vim/session/Session.vim

    "                            ┌─ if sth goes wrong, the function returns the string:
    "                            │       'echoerr '.string(v:exception)
    "                            │
    "                            │  we need to execute this string
    "                            │
    au BufWinEnter,VimLeavePre * exe mysession#auto_save()
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
augroup END

" auto_save {{{1

" This function saves the current session, iff `g:my_session` exists.
" In the session file, it adds the line:
"         let g:my_session = v:this_session
"
" … so that the next time we load the session, the plugin knows that it must
" track it automatically.
"
" It needs to be public to be callable from `manual_save()`.
" If we moved the latter here, we could make `auto_save()` script-local.
" We don't, to lazy-load as much code as we can.
"
" We can't move `auto_save()` in `autoload/`:
" it would defeat the whole purpose of `autoload/`, because `auto_save()` can be
" called when `VimEnter` is fired.

fu! mysession#auto_save() abort
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
        " Our session file will be updated next time (`BufWinEnter`, `VimLeavePre`).

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
            " We don't want to go on trying to save a session, if `Session.vim`
            " isn't writable for example.
            unlet! g:my_session
            " Next time we execute `:SessionSave`, we don't want it to use
            " `v:this_session` as a filepath. It just failed, so it could fail
            " again.
            let v:this_session = ':mksession failed'

            " Update all status lines, to remove the `[∞]` item, and let us
            " know that the current session is no longer being tracked.
            redrawstatus!

            return 'echoerr '.string(v:exception)
        endtry
    endif
    return ''
endfu

" My_session_status {{{1

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
