if exists('g:loaded_session')
    finish
endif
let g:loaded_session = 1

" TODO:
" Maybe we should consider removing the concept of a default session.
" We never use it, and it adds some complexity to the plugin.

" TODO:
" Maybe add a  command opening a buffer  showing all session names  with a short
" description.
" When you would select one, you would have a longer description in a popup window.

" TODO:
" When Vim  starts, we could  tell the plugin to  look for a  `session.vim` file
" inside the working  directory, and source it  if it finds one, then  use it to
" track the session.
" This would allow us to not have to name all our sessions.
" Also, `:STrack ∅` should save & track the current session in `:pwd`/session.vim.
" Update: Wait.  How would we pause the tracking of a session then?
" I guess it would  need to check whether a session is  being tracked (easy), or
" has been tracked in the past (tricky?)...

" Autocmds {{{1

augroup my_session | au!
    au StdInReadPost * let s:read_stdin = 1

    "               ┌ necessary to source ftplugins (trigger autocmds listening to BufReadPost?)
    "               │
    au VimEnter * ++nested call s:load_session_on_vimenter()

    " Purpose of the next 3 autocmds: {{{
    "
    "    1. automatically save the current session, as soon as `g:my_session`
    "       pops into existence
    "
    "    2. update the session file frequently, and as long as `g:my_session` exists
    "       IOW, track the session
    "}}}
    "                ┌ if sth goes wrong, the function returns the string:
    "                │      'echoerr '.string(v:exception)
    "                │
    "                │ we need to execute this string
    "                │
    au BufWinEnter * exe s:track(0)
    "  │
    "  └ We don't want the session to be saved only when we quit Vim,
    "    because Vim could exit abnormally.
    "
    "    Contrary to `BufEnter`, `BufWinEnter` is NOT fired for `:split`
    "    (without arguments), nor for `:split file`, `file` being already
    "    displayed in a window.
    "
    "    But most of the time, Vim won't quit abnormally, and the last saved
    "    state of our session will be performed when VimLeavePre is fired.
    "    So, `VimLeavePre` will have the final say most of the time.

    au TabClosed * call timer_start(0, { -> execute('exe ' .. expand('<SID>') .. 'track(0)') })
    " We also save whenever we close a tabpage, because we don't want
    " a closed tabpage to be restored while we switch back and forth between
    " 2 sessions with `:SLoad`.
    " But, we can't  save the session immediately, because for  some reason, Vim
    " would only save the last tabpage (or  the current one?).  So, we delay the
    " saving.

    " Why inspecting `v:servername`?{{{
    "
    " To not overwrite the `session/last` file if we're editing it outside a session.
    " We sometimes need to do this to debug some issue.
    "}}}
    " TODO: Why `MY_LAST_SESSION` is in uppercase?{{{
    "
    " To save it in viminfo? But we don't need it, since we use `session/last`, right?
    "
    " ---
    "
    " Same question for `MY_PENULTIMATE_SESSION`.
    "
    " ---
    "
    " If we don't need uppercase names,  write them in lowercase, and remove the
    " next `v:servername != ''` condition.
    "}}}
    au VimLeavePre * exe s:track(1)
        \ | if get(g:, 'MY_LAST_SESSION', '') != '' && v:servername != ''
        \ |     call writefile([g:MY_LAST_SESSION], $HOME .. '/.vim/session/last')
        \ | endif
    au User MyFlags call statusline#hoist('global',
        \ '%{session#status()}', 5, expand('<sfile>') .. ':' .. expand('<sflnum>'))
augroup END

" Commands {{{1

" Why `exe s:handle_session()` {{{
" and why `exe s:track()`?
"
" If an error occurs in a function, we'll get an error such as:
"
"     Error detected while processing function <SNR>42_track:~
"     line   19:~
"     Vim:E492: Not an editor command:             abcd~
"
" We want our  `:STrack` command, and our autocmd, to  produce a message similar
" to a regular  Ex command.  We don't  want the detail of  the implementation to
" leak.
"
" By using `exe function()`, we can get an error message such as:
"
"     Error detected while processing BufWinEnter Auto commands for "*":~
"     Vim:E492: Not an editor command:             abcd~
"
" How does it work?
" When an error may occur, we capture it and convert it into a string:
"
"     try
"         ...
"     catch
"         return 'echoerr ' .. string(v:exception)
"     endtry
"
" We execute this string in the context of `:STrack`, or of the autocmd.
" Basically, the try conditional + `exe function()` is a mechanism which lets us
" choose the context in which an error may occur.
" Note, however, that in this case, it prevents our `:WTF` command from capturing
" the error, because it will happen outside of a function.
"}}}

" We use `:echoerr` for `:SDelete`, `:SRename`, `:SClose`, because we want the
" command to disappear if no error occurs during its execution.
" For `:SLoad` and `:STrack`, we use `:exe` because there will always be
" a message to display; even when everything works fine.
com -bar          -complete=custom,s:suggest_sessions SClose  exe s:close()
com -bar -nargs=? -complete=custom,s:suggest_sessions SDelete exe s:delete(<q-args>)
com -bar -nargs=1 -complete=custom,s:suggest_sessions SRename exe s:rename(<q-args>)

com -bar       -nargs=? -complete=custom,s:suggest_sessions SLoad  exe s:load(<q-args>)
com -bar -bang -nargs=? -complete=file                      STrack exe s:handle_session(<bang>0, <q-args>)

" Functions "{{{1
fu s:close() abort "{{{2
    if !exists('g:my_session') | return '' | endif
    sil STrack
    sil tabonly | sil only | enew
    call s:rename_tmux_window('vim')
    return ''
endfu

fu s:delete(session) abort "{{{2
    if a:session is# '#'
        if exists('g:MY_PENULTIMATE_SESSION')
            let session_to_delete = g:MY_PENULTIMATE_SESSION
        else
            return 'echoerr "No alternate session to delete"'
        endif
    else
        let session_to_delete = a:session == ''
            \ ? get(g:, 'my_session', 'MY_LAST_SESSION')
            \ : fnamemodify(s:SESSION_DIR .. '/' .. a:session .. '.vim', ':p')
    endif

    if session_to_delete is# get(g:, 'MY_PENULTIMATE_SESSION', '')
        unlet! g:MY_PENULTIMATE_SESSION
    elseif session_to_delete is# get(g:, 'my_session', '')
        if exists('g:MY_PENULTIMATE_SESSION')
            " We have to load the alternate session *before* deleting the session
            " file, because `:SLoad#` will take a last snapshot of the current
            " session, which would restore the deleted file.
            SLoad#
            " The current session has just become the alternate one.
            " Since we're going to delete its file, make the plugin forget about it.
            unlet! g:MY_PENULTIMATE_SESSION
        else
            SClose
        endif
    endif

    " Delete the session file, and if sth goes wrong report what happened.
    if delete(session_to_delete)
        " Do *not* use `printf()`:{{{
        "
        "     return printf('echoerr "Failed to delete %s"', session_to_delete)
        "
        " It would fail when the name of the session file contains a double quote.
        "}}}
        return 'echoerr ' .. string('Failed to delete ' .. session_to_delete)
    endif
    return 'echo ' .. string(session_to_delete .. ' has been deleted')
endfu

fu s:handle_session(bang, file) abort "{{{2
    " We use `s:` to NOT have to pass them as arguments to various functions:{{{
    "
    "     s:should_delete_session()
    "     s:session_delete()
    "     s:should_pause_session()
    "     s:session_pause()
    "     s:where_do_we_save()
    "}}}
    let s:bang = a:bang
    let s:file = a:file
    " `s:last_used_session` is used by:{{{
    "
    "    - s:session_pause()
    "    - s:session_delete()
    "    - s:where_do_we_save()
    "
    " It's useful to be able to  delete a session which isn't currently tracked,
    " and to track the session using the session file of the last session used.
    "}}}
    let s:last_used_session = get(g:, 'my_session', v:this_session)

    try
        " `:STrack` should behave mostly like `:mksession` with the additional benefit of updating the session file.{{{
        "
        " However, we want 2 additional features:  pause/resume and deletion.
        "
        "     :STrack     pause/resume
        "     :STrack!    delete
        "}}}
        if s:should_pause_session()
            return s:session_pause()
        elseif s:should_delete_session()
            return s:session_delete()
        endif

        let s:file = s:where_do_we_save()
        if s:file == '' | return '' | endif

        " Don't overwrite an existing session file by accident.{{{
        "
        " Unless a bang is given.
        " Or unless `:STrack` was run without argument (in which case we want to
        " resume the tracking of a paused session).
        "}}}
        " Why `filereadable()`?{{{
        "
        " Well, we want  to prevent overwriting an existing session  file, so it
        " makes sense to check that the file does exist.
        "
        " Besides, if you  don't, then if you run `:STrack  foo`, while there is
        " no  `foo.vim` session  file, Vim  will just  run `:mksession`,  but it
        " won't set `g:my_session`, nor will it call `s:track()`.
        "
        " IOW, you'll create a regular session file, which won't be tracked.
        "}}}
        if !s:bang && a:file != '' && filereadable(s:file)
            return 'mksession ' .. fnameescape(s:file)
        endif

        let g:my_session = s:file
        " let `track()` know that it must save & track the current session

        " Why not simply return `s:track()`, and move the `echo` statement in the latter?{{{
        "
        " `s:track()`  is   frequently  called  by  the   autocmd  listening  to
        " `BufWinEnter`; we don't want the message to be echo'ed all the time.
        "
        " The message, and the renaming of the tmux pane, should only occur when
        " we begin the tracking of a new session.
        "}}}
        let error = s:track(0)
        if error == ''
            echo 'Tracking session in ' .. fnamemodify(s:file, ':~:.')
            call s:rename_tmux_window(s:file)
            return ''
        else
            return error
        endif

    finally
        redrawt
        unlet! s:bang s:file s:last_used_session
    endtry
endfu

fu s:load(session_file) abort "{{{2
    let session_file = a:session_file == ''
        \ ?     get(g:, 'MY_LAST_SESSION', '')
        \ : a:session_file is# '#'
        \ ?     get(g:, 'MY_PENULTIMATE_SESSION', '')
        \ : a:session_file =~# '/'
        \ ?     fnamemodify(a:session_file, ':p')
        \ :     s:SESSION_DIR .. '/' .. a:session_file .. '.vim'

    let session_file = resolve(session_file)

    if session_file == ''
        return 'echoerr "No session to load"'
    elseif !filereadable(session_file)
        " Do *not* use `printf()` like this:{{{
        "
        "     return fnamemodify(session_file, ':t')->printf('echoerr "%s doesn''t exist, or it''s not readable"')
        "}}}
        return 'echoerr '
            \ .. fnamemodify(session_file, ':t')
            \ ->printf("%s doesn't exist, or it's not readable")
            \ ->string()
    elseif exists('g:my_session') && session_file is# g:my_session
        return 'echoerr '
            \ .. fnamemodify(session_file, ':t')
            \ ->printf('%s is already the current session')
            \ ->string()
    else
        let [loaded_elsewhere, file] = s:session_loaded_in_other_instance(session_file)
        if loaded_elsewhere
            return 'echoerr '
                \ .. printf('%s is already loaded in another Vim instance', file)
                \ ->string()
        endif
    endif

    call s:prepare_restoration(session_file)
    let options_save = s:save_options()

    " Before restoring a session, we need to set the previous one (for `:SLoad#`).
    " The previous one is:
    "    - the current tracked session, if there's one
    "    - or the last tracked session, "
    if exists('g:my_session')
        let g:MY_PENULTIMATE_SESSION = g:my_session
    endif

    call s:tweak_session_file(session_file)
    "  ┌ Sometimes,  when the  session contains  one of  our folded  notes, an
    "  │ error is raised.  It seems some commands, like `zo`, fail to manipulate
    "  │ a fold, because it doesn't exist.  Maybe the buffer is not folded yet.
    "  │
    sil! exe 'so ' .. fnameescape(session_file)
    " During the sourcing, other issues may occur. {{{
    "
    " Every custom function that we invoke in any autocmd (vimrc, other plugin)
    " may interfere with the restoration process.
    " For an example, have a look at `s:dnb_clean()` in vimrc.
    "
    " To prevent any issue, we could restore the session while all autocmds are
    " disabled, THEN emit `BufReadPost` in all buffers, to execute the autocmds
    " associated to filetype detection:
    "
    "     noa so ~/.vim/session/default.vim
    "     doautoall <nomodeline> filetypedetect BufReadPost
    "                            │
    "                            └ $VIMRUNTIME/filetype.vim
    "
    " But, this would cause other issues:
    "
    "    - the filetype plugins would be loaded too late for markdown buffers
    "      → 'fdm', 'fde', 'fdt' would be set too late
    "      → in the session file, commands handling folds (e.g. `zo`) would
    "        raise `E490: No fold found`
    "
    "   - `doautoall <nomodeline> filetypedetect  BufReadPost` would only affect
    "   the file in which the autocmd calling the current function is installed
    "      → no syntax highlighting everywhere else
    "      → we would have to delay the command with a timer or maybe
    "        a one-shot autocmd
    "
    " Solution:
    " In an autocmd which may interfere with the restoration process, test
    " whether `g:SessionLoad` exists.  This variable only exists while a session
    " is being restored:
    "
    "     if exists('g:SessionLoad')
    "         return
    "     endif
    "}}}

    if exists('g:my_session')
        let g:MY_LAST_SESSION = g:my_session
    endif

    call s:restore_options(options_save)
    call s:restore_help_options()
    call s:rename_tmux_window(session_file)
    call s:win_execute_everywhere('norm! zv')

    " use the global arglist in all windows
    " Why is it needed?{{{
    "
    " Before saving a session, we remove the  global arglist, as well as all the
    " local arglists.
    " I think that because of this, the session file executes these commands:
    "
    "     arglocal
    "     silent! argdel *
    "
    " ... for every window.
    " The `:arglocal` causes all windows to use the local arglist by default.
    "
    " I don't want that.
    " By default, Vim uses the global arglist, which should be the rule.
    " Using a local arglist should be the exception.
    "}}}
    call s:win_execute_everywhere('argg')

    " reset height of window{{{
    "
    " Usually, this is not necessary.
    " But it's useful if the last time the session was saved you were focusing a
    " scratch buffer; such a buffer is  not restored, which causes the height of
    " the windows in the current tab page to be wrong.
    "}}}
    do <nomodeline> WinEnter

    " FIXME:
    " When we change the local directory of a window A, the next time
    " Vim creates a session file, it adds the command `:lcd some_dir`.
    " Because of this, the next time we load this session, all the windows
    " which are created after the window A inherit the same local directory.
    " They shouldn't.  We have excluded `'curdir'` from `'ssop'`.
    "
    " Open an issue on Vim's repo.
    " In the meantime,  we invoke a function  to be sure that  the local working
    " directory of all windows is `~/.vim`.
    "
    "     let orig = win_getid()
    "     tabdo windo cd ~/.vim
    "     call win_gotoid(orig)
    "
    " Update:
    " I've commented the code because it interferes with `vim-cwd`.
    "
    " ---
    "
    " I'm not sure the above is true.
    " When does Vim write `:lcd` in a session file?
    " It seems to do it even when I don't run `:lcd` manually...
    return ''
endfu

fu s:load_session_on_vimenter() abort "{{{2
    " Don't source the last session when we run `$ vim`; it's not always what we
    " want; source it only  when we run `$ nv`.  Note that  the default value of
    " `v:servername` is `VIM`.
    if v:servername isnot# 'VIM' | return | endif

    let file = $HOME .. '/.vim/session/last'
    if filereadable(file)
        let g:MY_LAST_SESSION = readfile(file)->get(0, '')
    endif

    " Why `/default.vim` in the pattern?{{{
    "
    " I don't like sourcing the  default session automatically; when it happens,
    " it's never  what I wanted,  and it's very  confusing, because I  lose time
    " wondering where the loaded files come from.
    "}}}
    " Why `^$` in the pattern?{{{
    "
    " If there's no last session, don't try to restore anything.
    "}}}
    if get(g:, 'MY_LAST_SESSION', '') =~# '/default.vim$\|^$'
        return
    endif

    if s:safe_to_load_session()
        exe 'SLoad ' .. g:MY_LAST_SESSION
    endif
endfu

fu s:prepare_restoration(file) abort "{{{2
    " Update current session file, before loading another one.
    exe s:track(0)

    " If the current session contains several tabpages, they won't be closed.
    " For some  reason, `:mksession` writes  the command `:only` in  the session
    " file,  but not  `:tabonly`.   So,  we make  sure  every tabpage/window  is
    " closed, before restoring a session.
    sil tabonly | sil only
    " │
    " └ if there's only 1 tab, `:tabonly` will display a message
endfu

fu s:rename(new_name) abort "{{{2
    let src = g:my_session
    let dst = expand(s:SESSION_DIR .. '/' .. a:new_name .. '.vim')

    if rename(src, dst)
        return 'echoerr ' .. string('Failed to rename ' .. src .. ' to ' .. dst)
    else
        let g:my_session = dst
        call s:rename_tmux_window(dst)
    endif
    return ''
endfu

fu s:rename_tmux_window(file) abort "{{{2
    if !exists('$TMUX') | return | endif

    "                                        ┌ remove head (/path/to/)
    "                                        │ ┌ remove extension (.vim)
    "                                        │ │
    let window_title = fnamemodify(a:file, ':t:r')
    sil call system('tmux rename-window -t ' .. $TMUX_PANE .. ' ' .. shellescape(window_title))

    augroup my_tmux_window_title | au!
        " We've just renamed the tmux window, so tmux automatically
        " disabled the 'automatic-rename' option.  We'll re-enable it when
        " we quit Vim.
        au VimLeavePre * sil call system('tmux set-option -w -t ' .. $TMUX_PANE .. ' automatic-rename on')
    augroup END
endfu

fu s:restore_help_options() abort "{{{2
    " Rationale:{{{
    "
    " Open a help file for a third-party plugin, then restart Vim (`SPC R`): the
    " file type is not set in the help file anymore.
    "
    " MWE:
    "
    "     $ vim +'h autocmd | tabnext | h vimtex | mksession! /tmp/.s.vim | qa!' -p ~/.shrc ~/.bashrc
    "     $ vim -S /tmp/.s.vim
    "
    " The issue can be fixed by adding `options` in `'ssop'`:
    "
    "     $ vim +'h autocmd | tabnext | h vimtex | set ssop+=options | mksession! /tmp/.s.vim | qa!' -p ~/.shrc ~/.bashrc
    "                                              ^---------------^
    "
    " But I don't want to include this  item; when loading a session, I want all
    " options to be reset with sane values.
    "}}}
    let rt_dirs = split(&rtp, ',')
    call remove(rt_dirs, index(rt_dirs, $VIMRUNTIME))
    call getwininfo()
        \ ->filter({_, v ->
        \     bufname(v.bufnr)->fnamemodify(':p') =~# '\m\C/doc/.*\.txt$'
        \     && index(rt_dirs, bufname(v.bufnr)->fnamemodify(':p:h:h')) != -1
        \ })
        \ ->map({_, v -> win_execute(v.winid, 'noswapfile set ft=help')})

    " to be totally reliable, this block must come after the previous one
    " Rationale:{{{
    "
    " Without, a few options are not properly restored in a help buffer:
    "
    "    - `'buflisted'`
    "    - `'buftype'`
    "    - `'foldenable'`
    "    - `'iskeyword'`
    "    - `'modifiable'`
    "
    " In particular, if `'isk'` is not correct, you may not be able to jump to a
    " tag (or preview it).
    "
    " MWE:
    "
    "     :h windows.txt
    "     /usr_07.txt
    "     SPC R
    "     :wincmd }
    "     E426: tag not found: usr_07~
    "
    " And if `'bt'` is not correct, there may still be some problematic tags:
    "
    "     :h :bufdo /'eventignore'
    "     SPC R
    "     :wincmd }
    "     E426: tag not found: eventignore~
    "
    " ---
    "
    " I found those options by comparing the output of `:setl` in a working help
    " buffer, and in a broken one.
    "
    " ---
    "
    " Alternatively,  you could  also  close  the help  window,  and re-run  the
    " relevant `:h topic` command.
    "
    " Including the  `localoptions` item in  `'ssop'` would also fix  the issue,
    " but I  don't want  to do  it, because when  loading a  session I  want all
    " options to be reset with sane values.
    "}}}
    let winids = getwininfo()->map({_, v -> v.winid})
    call filter(winids, {_, v -> getwinvar(v, '&ft') is# 'help'})
    noa call map(winids, {_, v -> win_execute(v, 'call s:restore_these()')})
endfu

fu s:restore_these() abort
    let &l:isk = '!-~,^*,^|,^",192-255,-'
    setl bt=help nobl nofen noma
endfu

fu s:restore_options(dict) abort "{{{2
    for [op, val] in items(a:dict)
        exe 'let &' .. op .. ' = ' .. (type(val) == v:t_string ? string(val) : val)
    endfor
endfu

fu s:safe_to_load_session() abort "{{{2
    return !argc()
        \ && !get(s:, 'read_stdin', 0)
        \ && &errorfile is# 'errors.err'
        \ && get(g:, 'MY_LAST_SESSION', s:SESSION_DIR .. '/default.vim')
        \     ->filereadable()
        \ && !get(g:, 'MY_LAST_SESSION', s:SESSION_DIR .. '/default.vim')
        \     ->s:session_loaded_in_other_instance()[0]

    " It's safe to automatically load a session during Vim's startup iff:
    "
    "     Vim is started with no files to edit.
    "     If there are files to edit we don't want their buffers to be
    "     immediately lost by a restored session.
    "
    "     Vim isn't used in a pipeline.
    "
    "     Vim wasn't started with the `-q` option.
    "
    "     There's a readable session file to load.
    "
    "     No file in the session is already loaded in other instance.
    "     Otherwise, loading it in a 2nd instance would raise the error E325.
endfu

fu s:save_options() abort "{{{2
    " Save values of options which will be changed by the session file (to restore them later):{{{
    "
    "    - `'shortmess'`
    "    - `'splitbelow'`
    "    - `'splitright'`
    "    - `'showtabline'`
    "    - `'winheight'`
    "    - `'winminheight'`
    "    - `'winminwidth'`
    "    - `'winwidth'`
    "}}}
    " I don't include the `options` item in `'ssop'`.  So, why do I need to save/restore these options?{{{
    "
    " Because Vim  *needs* to  temporarily change the  values of  these specific
    " options while restoring a session.
    " At  the end  of the  process, Vim  wants to  set those  options to  values
    " expected by the user.   The only values it knows the  user may expect, are
    " the ones which were used at the time the session file was created.
    " Therefore at the end of a session file, Vim writes `set winheight={current value}`:
    "
    "     $ vim -Nu NONE +'set winheight=123' +'mksession /tmp/.s.vim' +'qa!' && grep -n 'winheight' /tmp/.s.vim
    "     6:set winheight=123~
    "     23:set winheight=1~
    "     153:set winheight=123 winwidth=20 shortmess=filnxtToOS~
    "
    " But  this implies  that when  you load  a session,  these options  may not
    " be  preserved;  in  particular,  when  you restart  Vim,  and  the  latter
    " automatically  sources  the  last  session,   in  effect,  Vim  will  have
    " remembered the values of these options from the last session.
    " That's  not what  we want;  when  we restart,  we want  all custom  config
    " (options/mappings) to have been forgotten.
    "}}}
    return {
        \ 'shortmess': &shortmess,
        \ 'splitbelow': &splitbelow,
        \ 'splitright': &splitright,
        \ 'showtabline': &showtabline,
        \ 'winheight': &winheight,
        \ 'winminheight': &winminheight,
        \ 'winminwidth': &winminwidth,
        \ 'winwidth': &winwidth,
        \ }
endfu

fu s:session_loaded_in_other_instance(session_file) abort "{{{2
    let buffers = readfile(a:session_file)->filter({_, v -> v =~# '^badd '})

    if buffers ==# [] | return [0, 0] | endif

    " Never assign to a variable, the output of a function which operates in-place on a list:{{{
    "
    "     map()  filter()  reverse()  sort()  uniq()
    "
    " Unless, the list is the output of another function (including `copy()`):
    "
    "     let list = map([1, 2, 3], {_, v -> v + 1})             ✘
    "
    "     call map([1, 2, 3], {_, v -> v + 1})                 ✔
    "     let list = copy([1, 2, 3])->map({_, v -> v + 1})     ✔
    "     let list = tabpagebuflist()->map({_, v -> v + 1})    ✔
    "}}}
    " Why?{{{
    "
    " It gives you the wrong idea that the contents of the variable is a copy
    " of the original list/dictionary.
    " Ex:
    "
    "     let list1 = [1, 2, 3]
    "     let list2 = map(list1, {_, v -> v + 1})
    "
    " You may think that `list2` is a copy of `list1`, and that changing `list2`
    " shouldn't affect `list1`.  Wrong.  `list2`  is just another reference
    " pointing to `list1`.  Proof:
    "
    "     call map(list2, {_, v -> v + 2})
    "     increments all elements of `list2`, but also all elements of `list1`~
    "
    " A less confusing way of writing this code would have been:
    "
    "     let list1 = [1, 2, 3, 4, 5]
    "     call map(list1, {_, v -> v + 1})
    "
    " Without assigning  the output of `map()`  to a variable, we  don't get the
    " idea  that  we  have a  copy  of  `list1`.   And  if we  need  one,  we'll
    " immediately think about `copy()`:
    "
    "     let list1 = [1, 2, 3, 4, 5]
    "     let list2 = copy(list1)->map({_, v -> v + 1})
    "}}}
    call map(buffers, {_, v -> matchstr(v, '^badd +\d\+ \zs.*')})
    call map(buffers, {_, v -> fnamemodify(v, ':p')})

    let swapfiles = copy(buffers)->map(
        \ {_, v -> expand('~/.vim/tmp/swap/')
        \       .. substitute(v, '/', '%', 'g')
        \       .. '.swp'})
    call map(swapfiles, {_, v -> glob(v, 1)})->filter({_, v -> v != ''})
    "                                    │
    "                                    └ ignore 'wildignore'

    let a_file_is_currently_loaded = swapfiles !=# []
    let it_is_not_in_this_session = map(buffers, {_, v -> buflisted(v)})->index(1) == -1
    let file = get(swapfiles, 0, '')
    let file = fnamemodify(file, ':t:r')
    let file = substitute(file, '%', '/', 'g')
    return [a_file_is_currently_loaded && it_is_not_in_this_session, file]
endfu

fu s:session_delete() abort "{{{2
    call delete(s:last_used_session)

    " disable tracking of the session
    unlet! g:my_session

    "                reduce path relative to current working directory ┐
    "                                               don't expand `~` ┐ │
    "                                                                │ │
    echo 'Deleted session in ' .. fnamemodify(s:last_used_session, ':~:.')

    " Why do we empty `v:this_session`?
    "
    " If we don't, next time we try to save a session (:STrack),
    " the path in `v:this_session` will be used instead of:
    "
    "         ~/.vim/session/default.vim
    let v:this_session = ''
    return ''
endfu

fu s:session_pause() abort "{{{2
    echo 'Pausing session in ' .. fnamemodify(s:last_used_session, ':~:.')
    let g:MY_LAST_SESSION = g:my_session
    unlet g:my_session
    " don't empty `v:this_session`: we need it if we resume later
    return ''
endfu

fu s:should_delete_session() abort "{{{2
    "      ┌ :STrack! ∅
    "      ├────────────────────┐
    return s:bang && s:file == '' && filereadable(s:last_used_session)
    "                                │
    "                                └ a session file was used and its file is readable
endfu

fu s:should_pause_session() abort "{{{2
    "      ┌ no bang
    "      │          ┌ :STrack ∅
    "      │          │               ┌ the current session is being tracked
    "      │          │               │
    return !s:bang && s:file == '' && exists('g:my_session')
endfu

fu session#status() abort "{{{2

    " From the perspective of sessions, the environment can be in 3 states:
    "
    "    - no session has been loaded / saved
    "
    "    - a session has been loaded / saved, but is NOT tracked by our plugin
    "
    "    - a session has been loaded / saved, and IS being tracked by our plugin

    " We create the variable `state` whose value, 0, 1 or 2, stands for
    " the state of the environment.
    "
    "            ┌ a session has been loaded/saved
    "            │                       ┌ it's tracked by our plugin
    "            │                       │
    let state = (v:this_session != '') + exists('g:my_session')
    "            │
    "            └ stores the path to the last file which has been used
    "              to load/save a session;
    "              if no session has been saved/loaded, it's empty
    "
    " We can use this sum to express the state because there's no ambiguity.
    " Only 1 state can produce 0.
    " Only 1 state can produce 1.
    " Only 1 state can produce 2.
    "
    " If 2 states could produce 1, we could NOT use this sum.
    " More generally, we need a bijective, or at least injective, math function,
    " so that no matter the value we get, we can retrieve the exact state
    " which produced it.

    " return an item to display in the statusline
    "
    "       ┌ no session has been loaded/saved
    "       │     ┌ a session has been loaded/saved, but isn't tracked
    "       │     │      ┌ a session is being tracked
    "       │     │      │
    return ['', '[S]', '[∞]'][state]
endfu

fu s:suggest_sessions(arglead, _l, _p) abort "{{{2
    "           ┌ `glob()` performs 2 things:
    "           │
    "           │     - an expansion
    "           │     - a filtering:  only the files containing `a:arglead`
    "           │                     in their name will be expanded
    "           │
    "           │  ... so we don't need to filter the matches
    let files = glob(s:SESSION_DIR .. '/*' .. a:arglead .. '*.vim')
    " simplify the names of the session files:
    " keep only the basename (no path, no extension)
    return substitute(files, '[^\n]*\.vim/session/\([^\n]*\)\.vim', '\1', 'g')
    "                         ├───┘
    "                         └ in a regex used to describe text in a BUFFER
    "                           `.` stands for any character EXCEPT an end-of-line
    "
    "                           in a regex used to describe text in a STRING
    "                           `.` stands for any character INCLUDING an end-of-line
endfu

fu s:track(on_vimleavepre) abort "{{{2
    " This function saves the current session, iff `g:my_session` exists.
    " In the session file, it adds the line:
    "
    "     let g:my_session = v:this_session
    "
    " ... so that  the next time we  load the session, the plugin  knows that it
    " must track it automatically.

    if exists('g:SessionLoad')
        " `g:SessionLoad` exists temporarily while a session is loading.{{{
        "
        " See: :h SessionLoad-variable
        "
        " Suppose we source a session file:
        "
        "     :so file
        "
        " During the  restoration process, `BufWinEnter` would  be fired several
        " times.   Every time,  the current  function  would try  to update  the
        " session file.  This would overwrite the file, while it's being used to
        " restore the session.  We don't want that.
        "
        " The session file will be updated next time (`BufWinEnter`, `TabClosed`,
        " `VimLeavePre`).
        "}}}
        return ''
    endif

    " update the session  iff / as soon as  this variable exists
    if exists('g:my_session')
        try
            if a:on_vimleavepre
                " Why do it?{{{
                "
                " Because, Vim takes  a long time to re-populate  a long arglist
                " when sourcing a session.
                "
                " This is due to the fact that `:mksession` doesn't write in the
                " session file the same command we used to populate the arglist.
                " Instead, it executes `:argadd` for EVERY file in the arglist.
                "
                " MWE:
                "     :args $VIMRUNTIME/**/*.vim
                "     SPC R
                "}}}
                " Why not simply `%argd`?{{{
                "
                " It would fail  to remove a long local arglist  associated to a
                " window other than the currently focused one.
                "
                " MWE:
                "     :args $VIMRUNTIME/**/*.vim
                "     " focus another window
                "     SPC R
                "}}}
                " remove the global arglist
                argg | %argd
                " remove all the local arglists
                call s:win_execute_everywhere('argl | %argd')
            endif

            "             ┌ overwrite any existing file
            "             │
            exe 'mksession! ' .. fnameescape(g:my_session)

            " Let Vim know that this session is the last used.
            " Useful when we do this:
            "
            "     :STrack        stop the tracking of the current session
            "     :STrack new    create and track a new one
            "     :q             quit Vim
            "     $ vim          restart Vim
            let g:MY_LAST_SESSION = g:my_session

        catch /^Vim\%((\a\+)\)\=:E\%(788\|11\):/
            " About E788:{{{
            "
            " Since Vim  8.0.677, some  autocmds listening to  `BufWinEnter` may
            " not work all the time.  Sometimes they raise the error `E788`.
            " For us, it happens when we open the qf window (`:copen`).
            " Minimal vimrc to reproduce:
            "
            "     au BufWinEnter * mksession! /tmp/session.vim
            "     copen
            "
            " Basically, `:mksession` (temporarily?)  changes the current buffer
            " when 'ft' is set to 'qf', which is now forbidden.
            " For more info, search `E788` on Vim's bug tracker.
            "
            " Here, we simply ignore the error.
            " More generally, when we want to  do sth which is forbidden because
            " of a  lock, we  could use  `feedkeys()` and  a plug  mapping which
            " would execute arbitrary code:
            " https://github.com/vim/vim/issues/1839#issuecomment-315489118
            "}}}
            " About E11:{{{
            "
            " Since  Vim 8.1.2017,  running `:mksession`  from the  command-line
            " window raises `E11`.
            "
            "     Error detected while processing BufWinEnter Autocommands for "*":
            "     Vim(mksession):E11: Invalid in command-line window; <CR> executes, CTRL-C quits: mksession! /home/jean/.vim/session/C.vim
            "}}}
        catch
            " If sth  goes wrong now  (ex: session  file not writable),  it will
            " probably go wrong next time.
            " We don't want to go on trying to save a session.
            unlet! g:my_session
            " remove `[∞]` from the tab line
            redrawt
            return 'echoerr ' .. string(v:exception)
        endtry
    endif
    return ''
endfu

fu s:tweak_session_file(file) abort "{{{2
    "   ┌ lines of our session file
    "   │
    let body = readfile(a:file)

    " add the Ex command:
    "
    "     let g:my_session = v:this_session
    "
    " ... just before the last 3 commands:
    "
    "     doautoall SessionLoadPost
    "     unlet SessionLoad
    "     vim: set ft=vim : (modeline)
    call insert(body, 'let g:my_session = v:this_session', -3)
    " Why twice?{{{
    "
    " Once, I had an issue where this line was missing in a session file.
    " This  lead to  an issue  where, when  I restarted  Vim, the  wrong
    " session was systematically loaded.
    "}}}
    call insert(body, 'let g:my_session = v:this_session', -3)
    call writefile(body, a:file)
endfu

fu s:vim_quit_and_restart() abort "{{{2
    if has('gui_running') | echo 'not available in GUI' | return | endif
    "  ┌ there could be an error if we're in a terminal buffer (E382)
    "  │
    sil! update
    " Source:
    " https://www.reddit.com/r/vim/comments/5lj75f/how_to_reload_vim_completely_using_zsh_exit_to/

    " Send the signal `USR1` to the shell  parent of the current Vim process,
    " so that it restarts a new one when we'll get back at the prompt.
    " Do NOT use `:!`.{{{
    "
    " It would cause a hit-enter prompt when Vim restarts.
    "}}}
    let shell_parent_pid = '$(ps -p ' .. getpid() .. ' -o ppid=)'
    sil call system('kill -USR1 ' .. shell_parent_pid)

    " Note that the shell doesn't seem to process the signal immediately.
    " It doesn't restart a new Vim process, until we've quit the current one.
    " That's probably because  the shell stays in the background  as long as Vim
    " is running.
    qa!
endfu

fu s:where_do_we_save() abort "{{{2
    " :STrack ∅
    if s:file == ''
        if s:last_used_session == ''
            if !isdirectory(s:SESSION_DIR)
                call mkdir(s:SESSION_DIR, 'p', 0700)
            endif
            return s:SESSION_DIR .. '/default.vim'
        else
            return s:last_used_session
        endif

    " :STrack dir/
    elseif isdirectory(s:file)
        echohl ErrorMsg
        echo 'provide the name of a session file; not a directory'
        echohl NONE
        " Why don't you return anything?{{{
        "
        " Like:
        "
        "     return fnamemodify(s:file, ':p') .. 'default.vim'
        "
        " Because:
        "     :e ~/wiki/par/par.md
        "     :SClose
        "     :STrack par
        "     the session is saved in ~/wiki/par/default.vim~
        "     it should be in ~/.vim/session/par.vim~
        "
        " I think it's an argument in favor of not supporting the feature `:STrack dir/`.
        "}}}
        return ''

    " :STrack file
    else
        return s:file =~# '/'
            \ ?     fnamemodify(s:file, ':p')
            \ :     s:SESSION_DIR .. '/' .. s:file .. '.vim'
    endif
endfu

fu s:win_execute_everywhere(cmd) abort "{{{2
    let winids = getwininfo()->map({_, v -> v.winid})
    noa call map(winids, {_, v -> win_execute(v, a:cmd)})
endfu
"}}}1
" Mapping {{{1

nno <silent><unique> <space>R :<c-u>call <sid>vim_quit_and_restart()<cr>

" Options {{{1
" sessionoptions {{{2

" The default value contains many undesirable items:{{{
"
"    - blank: we don't want to save empty windows when `:mksession` is executed
"
"    - buffers: we don't want to restore hidden and unloaded buffers
"
"    - curdir: we don't want to save the current directory when we start Vim,
"      we want the current directory to be the same as the one in the shell,
"      otherwise it can lead to confusing situations when we use `**`
"
"    - folds: we don't want local fold options to be saved
"      (same reason as for 'options' item)
"      see also: https://github.com/Konfekt/FastFold/issues/57
"
"    - options: we don't want to save options and mappings,
"      because if we make some experiments and change some options/mappings
"      during a session, we don't want those to be restored;
"      only those written in files should be (vimrc, plugins, ...)
"
"      folding options are not affected by this item (for those you need the 'folds' item)
"}}}
set ssop=help,tabpages,winsize
"}}}1
" Variables {{{1

const s:SESSION_DIR = $HOME .. '/.vim/session'

" Documentation {{{1
"
" `:STrack` can receive 5 kind of names as arguments:
"
"    - nothing
"    - a new file (doesn't exist yet)
"    - an empty file (exists, but doesn't contain anything)
"    - a regular file
"    - a session file
"
" Also, `:STrack` can be suffixed with a bang.
" So, we can execute 10 kinds of command in total.
" They almost all track the session.
" This is a *design decision* (the command could behave differently).
" We design the command so that, by default, it tracks the current session,
" no matter the argument / presence of a bang.
" After all, this is its main purpose.
"
" However, we want to add 2 features: pause and deletion.
" And we don't want to overwrite an important file by accident.
" These are 3 special cases:
"
"    ┌──────────────────────┬─────────────────────────────────────────┐
"    │ :STrack              │ if the current session is being tracked │
"    │                      │ the tracking is paused                  │
"    ├──────────────────────┼─────────────────────────────────────────┤
"    │ :STrack!             │ if the current session is being tracked │
"    │                      │ the tracking is paused                  │
"    │                      │ AND the session file is deleted         │
"    ├──────────────────────┼─────────────────────────────────────────┤
"    │ :STrack regular_file │ fails (E189)                            │
"    └──────────────────────┴─────────────────────────────────────────┘
"
" ---
"
"    - `:STrack file`
"    - `:STrack /path/to/file`
"    - `:STrack relative/path/to/file`
"
" Invoke `:mksession` on:
"
"    - ~/.vim/session/file
"    - /path/to/file
"    - cwd/path/to/file
"
" ... iff `file` doesn't exist.
"
" Update the file whenever `BufWinEnter`, `TabClosed` or `VimLeavePre` is fired.
"
" ---
"
" `:STrack!` invokes `:mksession!`, which tries to overwrite the file no matter what.
"
" ---
"
"     :STrack
"
" If the tracking of a session is running:  pause it
" If the tracking of a session is paused:  resume it
"
" If  no  session is  being  tracked,  start  tracking  the current  session  in
" `~/.vim/session/default.vim`.
"
" TODO: It should be in:
"
"     `:pwd`/session.vim
"
" ---
"
"     :STrack!
"
" If no session is being tracked, begin the tracking.
" If the tracking of a session is running: pause it and remove the session file.
"
"
" Loading a session created with `:STrack` automatically resumes updates to that
" file.
"
" ---
"
"     :SDelete!
"     :SRename foo
"
" Delete current session.
" Rename current session into `~/.vim/session/foo`.
"
" ---
"
"     :SLoad
"
" Load last used session.  Useful after `:SClose`.
"
" ---
"
"     :SLoad#
"     :SDelete!#
"
" Load / Delete the previous session.
"
" ---
"
"     :SLoad foo
"     :SDelete! foo
"
" Load / Delete session `foo` stored in `~/.vim/session/foo.vim`.
"
" ---
"
"     :SLoad /path/to/session.vim
"
" Load session stored in `/path/to/session.vim`.
"
" TODO:
" Is it really useful?
" If not, remove this feature.
" I've added it because `:SLoad dir/` create  a session file in `dir/`, which is
" not `~/.vim/session`.
"
" If you keep it,  `:SLoad` should be able to suggest the names  of the files in
" `dir/`.
" It would  need to  deduce from  what you've typed,  whether it's  a part  of a
" session name, or of a path (relative/absolute) to a session file.
"
" ---
"
"     :SClose
"
" Close the session:  stop the tracking of the session, and close all windows
"
