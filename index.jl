/**
 * Module dependencies.
 * @private
 */HELP
// private npm modules
var express       = require('express');
var bodyParser    = require('body-parser');
var cookieParser  = require('cookie-parser');
var io_cookie     = require('socket.io-cookie-parser');
var fs            = require('fs');
var nodedump      = require('nodedump');
var multer        = require('multer');
var sha1          = require('sha1');

// exported npm modules
var path          = require('path');
var mv            = require('mv');

// local modules 
var pg            = require('./lib/pg');
var debug         = require('./lib/debug');
var send          = require('./lib/send');
// on crée l'app express
var app           = express();
var http          = require('http').Server(app);

// version secure
var sok;
try {
	var key   = fs.readFileSync('/usr/local/etc/artemis.key');
	var cert  = fs.readFileSync('/usr/local/etc/artemis.crt');
	var chain = fs.readFileSync('/usr/local/etc/digicert.crt');
	sok = true;
}
catch(e){
	sok = false;
}
if (sok) {
	var sapp  = express();
	var https = require('https').createServer({ key: key, cert: cert, ca: [chain] }, sapp);
}
	

// on crée l'app secure express
// var key     = fs.readFileSync('/opt/key.pem');
// var cert    = fs.readFileSync('/opt/cert.pem');
// var options = { key: key, cert: cert };
// var sapp    = express();
// var https   = require('https').createServer(options, sapp);


var io      = require('socket.io')(http);


JSON.stringifyAligned = require('json-align');
function sqlprint(params) {
	var printpar = [];
	for (var j in params) {
		if (params[j].length==0) {printpar.push("'"+params[j]+"'");continue;};
		if (!isNaN(Number(params[j]))) {printpar.push(Number(params[j]));continue;}
		if ((''+params[j]).toLowerCase()=='true') {printpar.push(true);continue;}
		if ((''+params[j]).toLowerCase()=='false') {printpar.push(false);continue;}
		if (params[j].constructor.name=='Array') {printpar.push('array['+sqlprint(params[j]).join()+']');continue;}
		printpar.push("'"+params[j]+"'");
	}
	return printpar;
}

/**
 * Module exports.
 * @public
 */

module.exports.up      = false;
module.exports.mv      = mv;
module.exports.path    = path;
module.exports.dump    = nodedump.dump;
module.exports.io      = io;
module.exports.upload  = multer({ dest: '/tmp/node_uploads', limits:{fileSize: 1000000} }).any();
module.exports.router  = express.Router;
// méthode d'initialisation du web server
// -> placement des routes prédéfinies
module.exports.server  = function(cfg) {
	// valeurs par défaut
  if (cfg !== undefined) {
    if (cfg.appdir  === undefined) cfg.appdir  = '.';
    if (cfg.verbose === undefined) cfg.verbose = true;
    if (cfg.port    === undefined) cfg.port    = 3000;
  }
  // on ne place les routes sur l'app express que lors du premier appel
  // les fois suivantes (s'il y en a ...) on renvoie juste l'app
  if (cfg !== undefined && !this.up) {
    // redéfinition du header express
    // Enise power !
    app.use(function(req,res,next){
      res.setHeader('X-Powered-By', 'Enise');
      next();
    });
		// traitement de cette stupide double requête
		// sur /favicon.ico au démarrage ...
		app.use(function(req,res,next){
			if (req.url === '/favicon.ico') {
				res.type('image/x-icon');
				res.status(200).end();
				return;
			}
			next();
		});
    // parsing des arguments POST
    // pour peupler req.body
    app.use(bodyParser.urlencoded({ extended: true }));
    // parsing des COOKIES
    // pour peupler req.cookies
    app.use(cookieParser());
    io.use(io_cookie());
		// messages console
    if (cfg.verbose) app.use(debug);
		// le cookie enise
    app.use(function (request, response, next) {
			if (request.cookies.enise == undefined) {
				var enise_id = sha1(Date.now()+request.ip);
				request.cookies.enise = enise_id;
				response.cookie('enise', enise_id);
			}
			next();
		});
    // utilisation du routeur principal de l'application
    // i.e. 'monapp/routes/index.js'
    var routes_path = path.join(path.dirname(module.parent.filename),cfg.appdir,'routes');
    var ok;
    try {
      ok = fs.statSync(routes_path).isDirectory();
    }
    // warning si l'application n'a pas de dossier 'routes'
    catch (e) {
      ok = false;
      //console.log("Warning : your application doesn't seem to have a 'routes' directory.");
    }
    try {
      // if faudrait tester ici si le fichier 'index.js' est absent
      // pour envoyer un warning dans la console
      if (ok) app.use(require(routes_path));
    }
    catch (e) {
      console.log(e);
    }
    // définition du serveur statique
    // il sert le répertoire 'monapp/public'
    var public_path = path.join(path.dirname(module.parent.filename), cfg.appdir,'site');
    try {
      ok = fs.statSync(public_path).isDirectory();
    }
    // warning si l'application n'a pas de dossier 'public'
    catch (e) {
      ok = false;
      console.log("Warning : your application doesn't seem to have a 'site' directory.");
    }
    try {
      if (ok) app.use(express.static(public_path));
    }
    catch (e) {
      console.log(e);
    }
    // traitement des requetes POST ou GET de type '/files/*' pour servir
    // les fichiers du dossier 'monapp/files'
    app.post('/files/:name', send(path.join(path.dirname(module.parent.filename), cfg.appdir,'files'), cfg.verbose));
    app.get('/files/:name', send(path.join(path.dirname(module.parent.filename), cfg.appdir,'files'), cfg.verbose));
		// traitement d'une requete d'execution de code sql
		app.post('/execsql', function(request, response) {
			var sqlreq   = request.body.sqlreq;
			var params   = request.body.params?request.body.params:[];
			var enise_id = request.body.enisecookie?request.cookies.enise:false;
			if (enise_id) params.splice(request.body.enisecookie,0,enise_id);
			var printstr = sqlreq;
			var printpar = sqlprint(params);
			for (var i=0; i<printpar.length ; i++) {
				var st = '$' + (i+1);
				printstr = printstr.split(st).join(printpar[i]);
			}
			console.log('SQL request :\n=> ' + printstr + ';');
			pg.sendresult(response, sqlreq, params);
		});
    // on peut maintenant accepter les connexions sur le port choisi
    http.listen(cfg.port, function(){
      this.up = true;
      console.log('Server is up on port',cfg.port);
    });

    // configuration de l'appli securisee
		if (sok) {
			sapp.use(function(req,res,next){
				res.setHeader('Access-Control-Allow-Origin', '*');
				next();
			});
			sapp.get('/', function(req,res){ res.status(200).end(); });
			https.listen(cfg.port-1);
		}
  }
  return app;
};	
// méthode d'initialisation du driver postgresql
// -> memorisation de la chaine de connexion
module.exports.pg = function(cfg) {
  if (cfg !== undefined) {
    pg.connectionString = 'postgres://'+cfg.user+':'+cfg.password
      +'@'+cfg.host+':5432/'+cfg.database;
  }
  return pg;
};
