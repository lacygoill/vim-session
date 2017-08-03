" TODO:
" Integrate this:
"           https://github.com/dhruvasagar/vim-prosession

augroup my_session_restore
    au!
    " FIXME:
    " prevent `:MSR` from restoring a session in a 2nd Vim instance
    " au VimEnter * nested MSR
    "             │
    "             └─ necessary to source ftplugins (trigger autocmds
    "             listening to bufread event?)
augroup END

" IFF {{{1
"
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

"     :MSV file
"
" Invoke `:mksession` on `file`.
"
" Continue to keep it updated until Vim exits, whenever `BufWinEnter`
" or `VimLeavePre` is fired. If `file` exists, it will be overwritten only
" if its contents looks like the one of a session file.
"
"     :MSV dir
"
" Invoke `:MSV` on `dir/Session.vim`.
"
"     :MSV
"
" If session tracking is already in progress, pause it.
" Otherwise, resume tracking or create a new session in the current directory.
"
"     :MSV!
"
" Same as `:MSV`, except that if tracking is in progress, `:MSV` not only pauses
" tracking, but it also removes the session file.
"
" Loading a session created with `:MSV` automatically resumes updates to that file.

" interface {{{1

"                                        ┌ My Session
"                                       ┌┤
"                                       ││┌─ saVe
"                                       │││
com! -bar -bang -complete=file -nargs=? MSV exe mysession#handle_session_file(<bang>0, <q-args>)
com! -bar -bang -complete=file -nargs=? MSR call mysession#restore(<q-args>)
"                                         │
"                                         └─ Restore

" autocmd {{{1

" This autocmd serves 2 purposes:
"
"     1. automatically save the current session, as soon as `g:my_session`
"        pops into existence
"
"     2. update the session file frequently, and as long as `g:my_session` exists
"        IOW, track the session
"
" We need the autocmd to be in this file, inside the `plugin/` directory.
" Otherwise, if we move it inside `autoload`, the plugin wouldn't resume tracking
" a restored session until `:MSV` is invoked. It would give this:
"
"         :MSV …
"         → call persist()
"         → source autoload/…
"         → install autocmd
"         → resume tracking
"
" We want the plugin to resume tracking, even if we manually load a previously
" tracked session:    :so ~/.vim/session/Session.vim
augroup my_session
    au!
    "                            ┌─ if sth goes wrong, the function returns the string:
    "                            │       'echoerr '.string(v:exception)
    "                            │
    "                            │  we need to execute this string
    "                            │
    au BufWinEnter,VimLeavePre * exe mysession#persist()
    "  │
    "  └─ We don't want the session to be saved only when we quit Vim,
    "     because Vim could exit abnormally.
    "     Tpope uses `BufEnter`, but `BufWinEnter` is much less frequent,
    "     and, hopefully, should be enough.
    "
    "     However:
    "     `BufWinEnter` is neither fired for `:split` without arguments,
    "     nor for `:split file`, file being already displayed in a window.
    "
    "     Anyway, most of the time, Vim won't quit abnormally, and the last
    "     saved state of our session will be performed when VimLeavePre is
    "     fired. So, `VimLeavePre` will have the final say most of the time.
augroup END

" persist() {{{1

" This function saves the current session, iff `g:my_session` exists.
" In the session file, it adds the line:
"         let g:my_session = v:this_session
"
" … so that the next time we load the session, the plugin knows that it must
" track it automatically.
"
" It needs to be public to be callable from `mysession#handle_session_file()`.
" If we moved `handle_session_file()` here, we could make `persist()` script-local.
"
" We can't move `persist()` in `autoload/`:  it would defeat the whole purpose
" of `autoload/`, because `persist()` is always called (`BufWinEnter`) from an autocmd.

fu! mysession#persist() abort
    " When `:mksession` creates a session file, it begins with the line:
    "
    "         let SessionLoad = 1
    "
    " And ends with:
    "
    "         unlet SessionLoad
    "
    " So, `g:SessionLoad` exists temporarily while a session is loading.
    " For more info: :h SessionLoad-variable
    "
    " Suppose we source a session file:
    "
    "       :so my_session_file
    "
    " During the restoration process, `BufWinEnter` will be emitted several
    " times. Every time, `persist()` will be invoked and try to update the
    " session file. This will overwrite the latter, while it's being used to
    " restore the session. So, we don't do anything.
    "
    " Our session file will be updated next time (`BufWinEnter`, `VimLeavePre`).

    if exists('g:SessionLoad')
        return ''
    endif

    " our plugin should update a session as soon as this variable exists
    if exists('g:my_session')
        try
            " create the session file
            "
            "             ┌─ overwrite any existing file
            "             │
            exe 'mksession! '.fnameescape(g:my_session)

            " `body` is a list whose items are the lines of our session file
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
            " We don't want `persist()` to go on trying to save a session, if
            " it can't access `Session.vim` for example.
            "
            " So, we get rid of `g:my_session`. This way, we have a single
            " error. No repetition.
            unlet! g:my_session

            " If sth goes wrong, we want to be informed.
            " Update all status lines, to remove the `[∞]` item, and let us
            " know that the current session is no longer being tracked.
            redrawstatus!

            " Finally, display the error message, so we have at least a clue of
            " what the problem is.
            return 'echoerr '.string(v:exception)
        endtry
    endif
    return ''
endfu

" My_session_status() {{{1

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

    return get([ '', '[S]', '[∞]' ], state, '')
    " We could also write:
    "         return [ '', '[S]', '[∞]' ][state]
    "
    " … but using `get()` may be a good idea, in case `state` gets a weird
    " value when sth goes wrong.
endfu

