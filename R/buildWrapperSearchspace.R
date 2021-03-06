
# Take the list of wrappers, a vector named by feature types indicating whether
# they have missings or not, the list of learner names by feature types /
# missings they can handle, and the list of all learners.
# return the set of "shadow" parameters which control wrapper behaviour,
# and the list of psuedoparameter replacements.
buildWrapperSearchSpace = function(wrappers, missings, canHandleX,
    allLearners) {
  outparams = list()
  wrapparams = makeParamSet()
  allTypes = c("factors", "ordered", "numerics")

  types.present = names(missings)

  converters = bwssConverters(wrappers)
  imputers = bwssImputers(wrappers)
  preprocs = bwssPreprocs(wrappers)

  can.convert = as.logical(any(extractSubList(wrappers, "is.converter")))
  can.impute = all(sapply(imputers[names(missings)][missings], length)) &&
      length(imputers[missings])
  can.convert.before.impute = all(sapply(imputers, length))

  imputeparam = "automlr.impute"
  miparam = "automlr.missing.indicators"
  convertanyparam = "automlr.convert"
  cbiparam = "automlr.convert.before.impute"

  ppnames = list()
  wanames = list()
  wrapagain = list()
  wimpnames = list()
  convparnames = list()  # type -> parname of automlr.convert.
  convtargetnames = list()  # type -> parname of automlr.convert.X.to
  for (type in allTypes) {
    convparnames[[type]] = sprintf("automlr.convert.%s", type)
    convtargetnames[[type]] = sprintf("automlr.convert.%s.to", type)
    wanames[[type]] = sprintf("automlr.wrapafterconvert.%s", type)
    wrapagain[[type]] = asQuoted(wanames[[type]])
    wimpnames[[type]] = sprintf("automlr.wimputing.%s", type)
    ppnames[[type]] = sprintf("automlr.preproc.%s", type)

  }

  # return something like quote(selected.learner %in% canHandleX[[type]])
  # but use TRUE of FALSE if this is always TRUE / FALSE.
  learnerCanHandleQuote = function(type) {
    if (setequal(allLearners, canHandleX[[type]])) {
      TRUE
    } else if (!length(canHandleX[[type]])) {
      FALSE
    } else {
      substitute(selected.learner %in% x, list(x = canHandleX[[type]]))
    }
  }

  # take a list of truth values indexed by type, giving the state of something
  # (presence, missingness) before conversion. This function generates the
  # expression that gives the respective state *after* conversion.
  transformProposition = function(proplist) {
    sapply(allTypes, function(totype) {
          noconversion = proplist[[totype]] %&&%
              qNot(asQuoted(convparnames[[totype]]))
          conversion = Reduce(`%||%`, lapply(setdiff(allTypes, totype),
              function(fromtype) {
                proplist[[fromtype]] %&&%
                    asQuoted(convparnames[[fromtype]]) %&&%
                    substitute(a == b, list(
                            a = asQuoted(convtargetnames[[fromtype]]),
                            b = totype))
              }), FALSE)
          noconversion %||% conversion
        }, simplify = FALSE)
  }

  # -------------------------------
  # indicators telling which types are present at each stage
  # -------------------------------

  # e.g. dtPresentAfterConv[[type]] is TRUE whenever 'type' data is present
  #   after conversion.

  # missings does not have all names, only the names of types that are actually
  # present.
  dtMissingBeforeConv = sapply(allTypes,
      function(x) isTRUE(as.list(missings)[[x]]))
  dtPresentBeforeConv = sapply(allTypes, function(x) x %in% types.present,
      simplify = FALSE)
  dtPresentBeforeConv$factors = dtPresentBeforeConv$factors %||%
      asQuoted(miparam)

  dtPresentAfterConv = transformProposition(dtPresentBeforeConv)
  dtMissingAfterConv = transformProposition(dtMissingBeforeConv)

  # dtWrap[[type]] is TRUE whenever wrapping is supposed to happen.
  dtWrap = sapply(allTypes, function(type) {
        (qNot(asQuoted(cbiparam)) %&&% dtPresentBeforeConv[[type]]) %||%
            (qNot(asQuoted(convparnames[[type]])) %&&%
              dtPresentBeforeConv[[type]]) %||%
            transformProposition(wrapagain)[[type]]
      }, simplify = FALSE)


  # ----------------------------
  # automlr.impute parameters
  # ----------------------------
  outparams %c=% makeLParam0Req(imputeparam,
      can.impute %&&% qNot(learnerCanHandleQuote("missings")),
      !can.impute)

  # ----------------------------
  # automlr.convert.X parameters
  # ----------------------------

  # param whether to convert at all
  outparams %c=% makeLParam0Req(convertanyparam,
      can.convert %&&% Reduce(`%||%`, lapply(allTypes, function(t)
                dtPresentBeforeConv[[t]] %&&% qNot(learnerCanHandleQuote(t)))),
      # automlr.convert is FALSE if either conversion can not happen, or
      # if there is exactly one type both in the data and in the learner's
      # capabilities.
      (!can.convert) %||% Reduce(`%||%`, lapply(allTypes, function(type) {
            Reduce(`%&&%`, lapply(setdiff(allTypes, type), function(otype) {
                      qNot(dtPresentBeforeConv[[otype]]) %&&%
                          qNot(learnerCanHandleQuote(otype))
                    }), TRUE) %&&%
            dtPresentBeforeConv[[type]] %&&% learnerCanHandleQuote(type)
          }), FALSE))

  for (type in allTypes) {
    eligible.targets = Filter(function(totype) {
          (totype != type) &&  # no identity conversion
              (length(converters[[type]][[totype]]))  # only if converters exist
        }, allTypes)

    convparamname = convparnames[[type]]

    halfreq = Reduce(`%||%`, lapply(eligible.targets, learnerCanHandleQuote),
        FALSE)
    req = asQuoted(convertanyparam) %&&% halfreq
        

    if (type == "factors") {
      mayproducefactors = learnerCanHandleQuote(type) %||% halfreq
      outparams %c=% makeLParam0Req(miparam, FALSE,
          qNot(any(missings) %&&% mayproducefactors))
    }

    req = dtPresentBeforeConv[[type]] %&&% req

    outparams %c=% makeLParam0Req(convparamname,
        qNot(learnerCanHandleQuote(type)) %&&% req,
        qNot(req))

    if (length(eligible.targets) > 1) {
      req = Reduce(`%&&%`, lapply(eligible.targets, learnerCanHandleQuote),
          TRUE) %&&% asQuoted(convparamname)
      outparams %c=% list(makeDiscreteParam(convtargetnames[[type]],
              values = eligible.targets, requires = setReq(req)))
    } else {
      outparams %c=% list(makeDiscreteParam(convtargetnames[[type]],
              values = list("null" = NULL), requires = setReq(FALSE)))
    }
    for (totype in eligible.targets) {
      index = which(totype == eligible.targets)
      other.targets = setdiff(eligible.targets, totype)

      # it is possible and easy to handle the case where there are more than
      # three types (and hence more than 2 eligible.targets), but the following
      # would need to change for that.
      assert(length(other.targets) <= 1)

      if (length(other.targets)) {
        is.only.conv = qNot(learnerCanHandleQuote(other.targets))
      } else {
        is.only.conv = TRUE
      }

      pname = sprintf("automlr.convert.%s.to.AMLRFIX%d", type, index)
      # dropping getReq(convparam) %&&% ..., because (A || B) && B == B.
      req = learnerCanHandleQuote(totype) %&&% is.only.conv %&&%
          asQuoted(convparamname)
      outparams %c=% list(makeDiscreteParam(pname, values = totype,
              requires = setReq(req)))

      pname = sprintf("automlr.wconverting.%s.to.%s", type, totype)
      req = learnerCanHandleQuote(totype) %&&% asQuoted(convparamname) %&&%
          substitute(a == b, list(
                  a = asQuoted(convtargetnames[[type]]),
                  b = totype))
      outparams %c=% list(
          makeDiscreteParam(pname,
              values = converters[[type]][[totype]], requires = setReq(req)),
          makeDiscreteParam(paste0(pname, ".AMLRFIX1"),
              values = "$", requires = setReq(qNot(req))))
      

      # Add the relevant wrapper's parameters to the exported param se
      # with the right conditionals.
      for (cname in converters[[type]][[totype]]) {
        wrapparams %c=% addParamSetSelectorCondition(
            wrappers[[cname]]$searchspace, pname, cname)
      }
    }
  }

  # -------------------------------
  # automlr.convert.before.impute
  # -------------------------------

  # 'automlr.convert.before.impute is only available if:
  # - can.convert.before.impute
  # - at least one convert param is TRUE
  #   - which means, the convert param's requirements must also be TRUE
  # - imputeparam is TRUE
  cbiReq = can.convert.before.impute %&&%
      Reduce(`%||%`, lapply(convparnames, asQuoted)) %&&%
      asQuoted(imputeparam)
  outparams %c=% makeLParam0Req(cbiparam, FALSE, qNot(cbiReq))

  # -------------------------------
  # automlr.wrapafterconvert.XXX
  # -------------------------------

  for (type in allTypes) {
    possible.targets = setdiff(allTypes, type)
    assert(length(possible.targets) == 2)
    wrappingHappens = substitute(if (a == b) acanconv else bcanconv,
        list(a = asQuoted(convtargetnames[[type]]), b = possible.targets[1],
            acanconv = length(preprocs[[possible.targets[1]]]) != 0,
            bcanconv = length(preprocs[[possible.targets[2]]]) != 0))
    wrapagainname = wanames[[type]]
    outparams %c=% makeLParam0Req(wrapagainname,
        asQuoted(cbiparam) %&&% asQuoted(convparnames[[type]]) %&&%
            wrappingHappens,
        qNot(asQuoted(convparnames[[type]]) %&&% wrappingHappens))
  }

  # -------------------------------
  # automlr.wimputing.XXX
  # -------------------------------

  for (type in allTypes) {
    if (!length(imputers[[type]])) {
      outparams %c=% list(makeDiscreteParam(wimpnames[[type]], values = "$"))
      next
    }
    wimpreq = (qNot(asQuoted(cbiparam)) %&&% dtMissingBeforeConv[[type]]) %||%
        (asQuoted(cbiparam) %&&% dtMissingAfterConv[[type]])
    outparams %c=% list(makeDiscreteParam(wimpnames[[type]],
        values = imputers[[type]],
        requires = setReq(asQuoted(imputeparam) %&&% wimpreq)))
    outparams %c=% list(makeDiscreteParam(
            paste0(wimpnames[[type]], ".AMLRFIX1"), values = "$",
        requires = setReq(qNot(asQuoted(imputeparam) %&&% wimpreq))))
    for (iname in imputers[[type]]) {
      wrapparams %c=% addParamSetSelectorCondition(
          wrappers[[iname]]$searchspace, wimpnames[[type]], iname)
    }
  }

  # -------------------------------
  # automlr.preproc.XXX
  # -------------------------------

  for (type in allTypes) {
    ppname = ppnames[[type]]
    outparams %c=% list(makeDiscreteParam(ppname,
        values = listWrapperCombinations(preprocs[[type]]),
        requires = setReq(dtWrap[[type]])))
    outparams %c=% list(makeDiscreteParam(paste0(ppname, ".AMLRFIX1"),
        values = "$", requires = setReq(qNot(dtWrap[[type]]))))
    for (pname in preprocs[[type]]) {
      wrapparams %c=% addParamSetCondition(wrappers[[pname]]$searchspace,
          substitute(b %in% strsplit(a, "$", fixed = TRUE)[[1]],
              list(a = asQuoted(ppname), b = pname)))
    }
  }

  replacelist = dtPresentAfterConv
  names(replacelist) = paste0("automlr.has.", names(replacelist))
  replacelist$automlr.has.missings = any(missings) %&&%
      qNot(asQuoted(imputeparam))

  list(wrapperps = c(wrapparams, makeParamSet(params = outparams)),
      replaces = replacelist)
}

#################################
# Requirement Helpers           #
#################################

`%&&%` = function(a, b) {
  if (isTRUE(a)) {
    return(b)
  }
  if (isFALSE(a) || isFALSE(b)) {
    return(FALSE)
  }
  if (isTRUE(b)) {
    return(a)
  }
  substitute(a && b, list(a = a, b = b))
}

`%||%` = function(a, b) {
  if (isFALSE(a)) {
    return(b)
  }
  if (isTRUE(a) || isTRUE(b)) {
    return(TRUE)
  }
  if (isFALSE(b)) {
    return(a)
  }
  substitute(a || b, list(a = a, b = b))
}

qNot = function(a) {
  if (isFALSE(a)) {
    TRUE
  } else if (isTRUE(a)) {
    FALSE
  } else {
    substitute(!a, list(a = a))
  }
}

# call this as in 'makeParam(..., requires = setReq(requirement))`
setReq = function(r) {
  if (isTRUE(r)) {
    NULL
  } else if (class(r) != "call") {
    substitute(identity(r), list(r = r))
  } else {
    r
  }
}

# get a parameter's 'requires' or TRUE if no requires present.
getReq = function(r) {
  req = r$requires
  if (is.null(req)) {
    TRUE
  } else if (length(req) == 2 && identical(req[[1]], quote(identity))) {
    req[[2]]
  } else {
    req
  }
}

# make a logical param which only appears when both 'alwaysTrueReq'
# and 'alwaysFalseReq' are FALSE. Otherwise, use AMLRFIX-magic to
# set the parameter to TRUE / FALSE, depending on the requirements.
# assumes alwaysTrueReq and alwaysFalseReq are mutually exclusive.
makeLParam0Req = function(id, alwaysTrueReq, alwaysFalseReq) {
  list(
      makeLogicalParam(id, requires = setReq(
              qNot(alwaysFalseReq) %&&% qNot(alwaysTrueReq))),
      makeDiscreteParam(paste0(id, ".AMLRFIX1"),
          values = list(`TRUE` = TRUE),
          requires = setReq(alwaysTrueReq)),
      makeDiscreteParam(paste0(id, ".AMLRFIX2"),
          values = list(`FALSE` = FALSE),
          requires = setReq(alwaysFalseReq)))
}

#################################
# Wrapper lists                 #
#################################

bwssConverters = function(wrappers) {
  allTypes = c("factors", "ordered", "numerics")
  cwrappers = wrappers[extractSubList(wrappers, "is.converter")]
  converters = list()  # a list source -> destination -> converternames
  for (type in allTypes) {
    converters[[type]] = list()
  }
  for (cw in cwrappers) {
    converters[[cw$convertfrom]][[cw$datatype]] %c=% cw$name
  }
  converters
}

bwssImputers = function(wrappers) {
  iwrappers = wrappers[extractSubList(wrappers, "is.imputer")]
  imputers = list()
  for (iw in iwrappers) {
    imputers[[iw$datatype]] %c=% iw$name
  }
  imputers
}

bwssPreprocs = function(wrappers) {
  ppwrappers = wrappers[(!extractSubList(wrappers, "is.imputer")) &
          (!extractSubList(wrappers, "is.converter"))]
  preprocs = list()
  for (pw in ppwrappers) {
    preprocs[[pw$datatype]] %c=% pw$name
  }
  preprocs
}

# get the possible values of preprocessor-wrapper parameters
# these are $-separated lists of names in the order the preprocessors are
# applied.
listWrapperCombinations = function(ids) {
  combineNames = function(x) {
    if (all(!duplicated(x))) {
      paste(x, collapse = "$")
    }
  }
  result = sapply(seq_along(ids), function(l) {
        apply(expand.grid(rep(list(ids), l)), 1, combineNames)
      })
  # add "no wrappers" option. The empty string
  # causes errors, however.
  result = c("$", result)
  unlist(result)
}

#################################
# Wrapper ParamSets             #
#################################

# modify the ParamSet so that every element has an additional condition
# added to its requirements.
addParamSetCondition = function(ps, cond) {
  for (n in names(ps$pars)) {
    if (is.null(ps$pars[[n]]$requires)) {
      ps$pars[[n]]$requires = cond
    } else {
      ps$pars[[n]]$requires = substitute((a) && (b), list(
              a = cond, b = ps$pars[[n]]$requires))
    }
  }
  ps
}

# modify the ParamSet so that every element has the additional condition of
# the parameter 'selector' equaling 'selectand'. This is used when wrapper
# parameters depend on a wrapper selector actually selecting that wrapper to
# have an effect.
addParamSetSelectorCondition = function(ps, selector, selectand) {
  addParamSetCondition(ps, substitute(x == y, list(x = asQuoted(selector),
              y = selectand)))
}

#################################
# Wrapper Building              #
#################################


buildCPO = function(args, wrappers) {

  allTypes = c("factors", "ordered", "numerics")

  propToType = function(p) switch(p, factors = "factor", numerics = "numeric",
        ordered = "ordered", stop("unknown property"))

  setProperArgs = function(cpo) {
    hpnames = intersect(names(getParamSet(cpo)$pars), names(args))
    setHyperPars(cpo, par.vals = args[hpnames])
  }

#  applyCpoToType = function(cpo, type, level) {
#    sname = sprintf("automlr.selector.%s.%d", type, level)
#    snameinv = paste0(sname, ".inv")
#    cpoCbind(cpoSelect(type = propToType(type), id = sname) %>>% cpo,
#        cpoSelect(type = type, invert = TRUE, id = snameinv))
#  }

  applyTypeCPOs = function(cpos, selector.id.prefix) {
    uniprefix = "automlr."
    cols = lapply(allTypes, function(t) {
          cpoSelect(type = propToType(t),
              id = paste0(uniprefix, selector.id.prefix, t)) %>>% cpos[[t]]
        })
    names(cols) = paste0(selector.id.prefix, allTypes)
    cbound = do.call(cpoCbind, cols)
    cbound = setProperArgs(cbound)
    cpoApply(cbound, id = paste0(uniprefix, selector.id.prefix))
  }

  impute.cpo = NULLCPO
  convert.cpo = NULLCPO

  pppipeline = list()

  for (type in allTypes) {
    wpreproc = sprintf("automlr.preproc.%s", type)
    pppipeline[[type]] = NULLCPO
    if (args[[wpreproc]] == "$") {
      next
    }
    for (pp in strsplit(args[[wpreproc]], "$", TRUE)[[1]]) {
      pppipeline[[type]] = pppipeline[[type]] %>>% wrappers[[pp]]
    }
    pppipeline[[type]] = setProperArgs(pppipeline[[type]])
  }

  pp.cpo = applyTypeCPOs(pppipeline, "ppselect.")
  pp.cpo$properties$properties = union(c("factors", "numerics", "ordered"),
      pp.cpo$properties$properties)
  pp.cpo$par.vals$automlr.ppselect..cpo$properties = pp.cpo$properties

  if (args$automlr.impute) {
    impute.cpo = applyTypeCPOs(sapply(allTypes, function(type) {
                    wimp = args[[sprintf("automlr.wimputing.%s", type)]]
                    if (wimp == "$") {
                        NULLCPO
                    } else {
                      wrappers[[wimp]]
                    }
                }, simplify = FALSE), "impselect.")
    impute.cpo$properties$properties.adding = "missings"
    impute.cpo$par.vals$automlr.impselect..cpo$properties =
        impute.cpo$properties
  }

  if (args$automlr.convert) {
    convert.cpo = applyTypeCPOs(sapply(allTypes, function(type) {
              if (!args[[sprintf("automlr.convert.%s", type)]]) {
                return(NULLCPO)
              }
              totype = args[[sprintf("automlr.convert.%s.to", type)]]
              wconv = args[[sprintf("automlr.wconverting.%s.to.%s", type,
                      totype)]]
              if (!args$automlr.convert.before.impute &&
                  args[[sprintf("automlr.wrapafterconvert.%s", type)]]) {
                wrappers[[wconv]] %>>% cpoApply(pppipeline[[totype]],
                    id = paste0("automlr.postconvertcpo.", type))
              } else {
                wrappers[[wconv]]
              }
            }, simplify = FALSE), "convselect.")
    fromconv = character(0)
    toconv = character(0)
    for (type in allTypes) {
      if (!args[[sprintf("automlr.convert.%s", type)]]) {
        next
      }
      fromconv %c=% type
      toconv %c=% args[[sprintf("automlr.convert.%s.to", type)]]
    }
    noconv = intersect(fromconv, toconv)
    fromconv = setdiff(fromconv, noconv)
    toconv = setdiff(toconv, noconv)
    convert.cpo$properties$properties = union(
        c("factors", "numerics", "ordered"), convert.cpo$properties$properties)
    convert.cpo$properties$properties.adding = fromconv
    convert.cpo$properties$properties.needed = toconv
    convert.cpo$par.vals$automlr.convselect..cpo$properties =
        convert.cpo$properties
  }

  fullcpo = NULLCPO
  if (args$automlr.convert.before.impute) {
    if (args$automlr.missing.indicators) {
      fullcpo = cpoCbind(NULLCPO, missing.factors = cpoMissingIndicators())
    }
    fullcpo = fullcpo %>>% convert.cpo %>>% impute.cpo %>>% pp.cpo
  } else {
    if (args$automlr.missing.indicators) {
      fullcpo = cpoCbind(impute.cpo, missing.factors = cpoMissingIndicators())
    } else {
      fullcpo = impute.cpo
    }
    fullcpo = fullcpo %>>% pp.cpo %>>% convert.cpo
  }
  fullcpo
}





