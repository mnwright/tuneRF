#' tuneRF
#' 
#' Automatic tuning of random forests of the (\code{\link[ranger]{ranger}}) package with one line of code. 
#'
#' @param task The mlr task created by \code{\link[mlr]{makeClassifTask}} or \code{\link[mlr]{makeRegrTask}}. 
#' @param measure Performance measure to evaluate. Default is auc for classification and mse for regression. Other possible performance measures can be looked up here: https://mlr-org.github.io/mlr-tutorial/release/html/performance/index.html
#' @param iters Number of iterations. 
#' @param num.threads Number of threads. Default is number of CPUs available.
#' @param num.trees Number of trees.
#' @param parameters Optional list of fixed named parameters that should be passed to \code{\link[ranger]{ranger}}.
#' @param tune.parameters Optional character vector of parameters that should be tuned. 
#' Default is mtry, min.node.size and sample.fraction. Additionally replace and respect.unordered.factors can be 
#' included in the tuning process.
#' @param save.file.path File to which interim results are saved. Default is optpath.RData in the current working 
#' directory. If one iteration fails the algorithm can be started again with \code{\link{restartTuneRF}}.
#' @param build.final.model [\code{logical(1)}]\cr
#'   Should the best found model be fitted on the complete dataset?
#'   Default is \code{TRUE}. 
#' @param show.info Verbose mlrMBO output on console? Default is \code{TRUE}.
#' @import mlr mlrMBO ParamHelpers
#' @return list with recommended parameters and a data.frame with all evaluated hyperparameters and performance and time results for each run
#' @details Model based optimization is used as tuning strategy and the three parameters min.node.size, sample.fraction and mtry are tuned at once. Out-of-bag predictions are used for evaluation, which makes it much faster than other packages and tuning strategies that use for example 5-fold cross-validation. Classification as well as regression is supported. 
#' The measure that should be optimized can be chosen from the list of measures in mlr: http://mlr-org.github.io/mlr-tutorial/devel/html/measures/index.html
#' @seealso \code{\link{estimateTimeTuneRF}} for time estimation.
#' @export
#' @examples 
#' \dontrun{
#' library(tuneRF)
#' library(mlr)
#' 
#' # A mlr task has to be created in order to use the package
#' # the already existing iris task is used here
#' unlink("./optpath.RData")
#' estimateTimeTuneRF(iris.task)
#' 
#' res = tuneRF(iris.task, measure = list(multiclass.brier), num.trees = 1000, 
#'   num.threads = 2, iters = 100)
#'   
#' # Mean of best 5 % of the results
#' res
#' # Model with the new tuned hyperparameters
#' res$model}
tuneRF = function(task, measure = NULL, iters = 100, num.threads = NULL, num.trees = 1000, 
  parameters = list(replace = TRUE, respect.unordered.factors = TRUE), 
  tune.parameters = c("mtry", "min.node.size", "sample.fraction"), save.file.path = "./optpath.RData",
  build.final.model = TRUE, show.info = getOption("mlrMBO.show.info", TRUE)) {
  
  unlink(save.file.path)
  
  fixed.param.in.tune = names(parameters) %in% tune.parameters
  if(any(fixed.param.in.tune))
    stopf("Fixed parameter %s cannot be tuning parameter at the same time.", names(parameters)[fixed.param.in.tune][1])
  
  type = getTaskType(task)
  size = getTaskSize(task)
  NFeats = getTaskNFeats(task)
  
  predict.type = ifelse(type == "classif", "prob", "response")
  if(is.null(measure)) {
    if(type == "classif") {
      cls.levels = getTaskClassLevels(iris.task)
      if(length(cls.levels) == 2) {
        measure = list(brier)
      } else {
        measure = list(multiclass.brier)
      }
    }
    if(type == "regr") {
      measure = list(mse)
    }
  }
  measure.name = measure[[1]]$id
  minimize = measure[[1]]$minimize
  
  # Set the number of threads if not given by user
  if(is.null(num.threads))
    num.threads = detectCores()
  
  # Evaluation function
  performan = function(x) {
    par.vals = c(x, num.trees = num.trees, num.threads = num.threads, parameters)
    lrn = makeLearner(paste0(type, ".ranger"), par.vals = par.vals, predict.type = predict.type)
    mod = mlr::train(lrn, task)
    preds = getOOBPreds(mod, task)
    performance(preds, measures = measure)
  }
  
  # Transformation of nodesize
  trafo_nodesize = function(x) ceiling(2^(log(size * 0.2, 2) * x))
  # Its ParamSet
  ps = makeParamSet(
    makeIntegerParam("mtry", lower = 1, upper = NFeats),
    makeNumericParam("min.node.size", lower = 0, upper = 1, trafo = trafo_nodesize), 
    makeNumericParam("sample.fraction", lower = 0.22, upper = 1),
    makeLogicalParam(id = "replace", default = TRUE),
    makeLogicalParam(id = "respect.unordered.factors", default = FALSE)
  )
  tunable.parameters = c("mtry", "min.node.size", "sample.fraction", "replace", "respect.unordered.factors")
  ps$pars = ps$pars[tunable.parameters %in% tune.parameters]
  
  # Budget
  f.evals = iters
  mbo.init.design.size = 30
  
  # Focus search
  infill.opt = "focussearch"
  mbo.focussearch.points = iters
  mbo.focussearch.maxit = 3
  mbo.focussearch.restarts = 3
  
  # The final SMOOF objective function
  objFun = makeMultiObjectiveFunction(
    name = "reg",
    fn = performan,
    par.set = ps,
    has.simple.signature = FALSE,
    noisy = TRUE,
    n.objectives = 1,
    minimize = minimize
  )
  
  # Build the control object
  method = "parego"
  if (method == "parego") {
    mbo.prop.points = 1
    mbo.crit = "cb"
    parego.crit.cb.pi = 0.5
  }
  
  control = makeMBOControl(n.objectives = 1L, propose.points = mbo.prop.points, # impute.y.fun = function(x, y, opt.path) 0.7, 
    save.on.disk.at = 1:(iters-30+1), save.file.path = save.file.path)
  control = setMBOControlTermination(control, max.evals = f.evals, iters = 300)
  control = setMBOControlInfill(control, #opt = infill.opt,
    opt.focussearch.maxit = mbo.focussearch.maxit,
    opt.focussearch.points = mbo.focussearch.points,
    opt.restarts = mbo.focussearch.restarts)
  
  design = generateDesign(mbo.init.design.size, getParamSet(objFun), fun = lhs::maximinLHS)
  #mbo.learner = makeLearner("regr.randomForest", predict.type = "se")
  mbo.learner = makeLearner("regr.km", covtype = "matern3_2", optim.method = "BFGS", nugget.estim = TRUE, 
    jitter = TRUE, predict.type = "se", config = list(show.learner.output = FALSE))
  
  result = mbo(fun = objFun, design = design, learner = mbo.learner, control = control, show.info = show.info)
  
  res = data.frame(result$opt.path)
  if("min.node.size" %in% tune.parameters)
    res$min.node.size = trafo_nodesize_end(res$min.node.size, size)
  colnames(res)[colnames(res) == "y"] = measure.name
  res = res[, c(tune.parameters, measure.name, "exec.time")]
  
  if (minimize) {
    recommended.pars = lapply(res[res[, measure.name] <= quantile(res[, measure.name], 0.05),], summaryfunction)
  } else {
    recommended.pars = lapply(res[res[, measure.name] >= quantile(res[, measure.name], 0.95),], summaryfunction)
  }
  recommended.pars = data.frame(recommended.pars)
  recommended.pars[colnames(res) %in% c("min.node.size", "mtry")] = round(recommended.pars[colnames(res) %in% c("min.node.size", "mtry")])
  
  # save the model with recommended hyperparameters
  mod = if(build.final.model) {
    ln.rec.pars = length(recommended.pars)
    x = as.list(recommended.pars[-c(ln.rec.pars - 1, ln.rec.pars)])
    x = c(x, num.trees = num.trees, num.threads = num.threads, parameters)
    lrn = makeLearner(paste0(type, ".ranger"), par.vals = x, predict.type = predict.type)
    mlr::train(lrn, task)
  } else {
    NULL
  }
  
  unlink(save.file.path)
  
  out = list(recommended.pars = recommended.pars, results = res, model = mod)
  class(out) = "tuneRF"
  return(out)
}

#' @export
print.tuneRF = function(x) {
  cat("Recommended parameter settings:", "\n")
  ln = length(x$recommended.pars)
  print(x$recommended.pars[-c(ln-1, ln)])
  cat("Results:", "\n")
  print(x$recommended.pars[c(ln-1, ln)])
}

#' @export
trafo_nodesize_end = function(x, size) ceiling(2^(log(size * 0.2, 2) * x))

#' @export
summaryfunction = function(x) ifelse(class(x) %in% c("numeric", "integer"), mean(x), 
  names(sort(table(x), decreasing = TRUE)[1]))