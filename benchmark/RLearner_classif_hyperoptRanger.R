makeRLearner.classif.hyperoptRanger = function() {
  makeRLearnerClassif(
    cl = "classif.hyperoptRanger",
    package = "mlrHyperopt",
    par.set = makeParamSet(
    ),
    properties = c("twoclass", "multiclass", "prob", "numerics", "factors", "ordered", "featimp", "weights"),
    name = "Random Forests",
    short.name = "hyperoptRanger",
    note = "By default, internal parallelization is switched off (`num.threads = 1`), `verbose` output is disabled, `respect.unordered.factors` is set to `TRUE`. All settings are changeable.",
    callees = "hyperoptRanger"
  )
}

# make Own parameter configuration
par.set = makeParamSet(
  makeIntegerParam(
    id = "mtry",
    lower = 1,
    upper = expression(p),
    default = expression(round(p^0.5))),
  makeIntegerParam(
    id = "min.node.size",
    lower = 1,
    upper = expression(round(n/10)),
    default = 1),
  keys = c("p", "n"))
par.config = makeParConfig(
  par.set = par.set,
  par.vals = list(num.trees = 2000),
  learner.name = "ranger"
)

trainLearner.classif.hyperoptRanger = function(.learner, .task, .subset, .weights = NULL, ...) {
  res = hyperopt(.task, learner = "classif.ranger", par.config = par.config)
  lrn = setPredictType(res$learner, .learner$predict.type)
  train(lrn, .task, subset = .subset, weights = .weights)
}

predictLearner.classif.hyperoptRanger = function(.learner, .model, .newdata, ...) {
  model = .model$learner.model$learner.model
  p = predict(object = model, data = .newdata, ...)
  return(p$predictions)
}