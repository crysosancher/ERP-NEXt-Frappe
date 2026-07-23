(function () {
	function byId(id) {
		return document.getElementById(id);
	}

	function setNotice(text, isError) {
		var notice = byId("saas-notice");
		notice.textContent = text || "";
		notice.classList.toggle("hidden", !text);
		notice.classList.toggle("error", !!isError);
	}

	/* ─── Progress ring ─────────────────────────────────────────────────── */
	var PROGRESS_RING_WRAP, RING_FILL;
	var RING_CIRCUMFERENCE = 326.73;
	var progressTimer = null;
	var progressStep = -1;   // -1 = not started

	function getProgressEl() {
		if (!PROGRESS_RING_WRAP) {
			PROGRESS_RING_WRAP = byId("progress-ring-wrap");
			RING_FILL = document.querySelector(".progress-ring_fill");
		}
		return { wrap: PROGRESS_RING_WRAP, fill: RING_FILL };
	}

	function showProgressRing() {
		var el = getProgressEl();
		el.wrap.classList.remove("hidden");
		progressStep = -1;
		// reset ring
		el.fill.style.strokeDashoffset = 326.73;
		document.querySelectorAll(".progress-step").forEach(function (s) {
			s.classList.remove("active", "done");
		});
	}

	function hideProgressRing() {
		var el = getProgressEl();
		el.wrap.classList.add("hidden");
		if (progressTimer) {
			clearInterval(progressTimer);
			progressTimer = null;
		}
		progressStep = -1;
	}

	function activateStep(step) {
		// mark all lower steps done
		document.querySelectorAll(".progress-step").forEach(function (s) {
			var n = parseInt(s.dataset.step, 10);
			s.classList.remove("active");
			if (n < step) s.classList.add("done");
			else if (n === step) s.classList.add("active");
			else s.classList.remove("done");
		});
		// fill ring proportionally: step / 3 * circumference
		var el = getProgressEl();
		var offset = RING_CIRCUMFERENCE * (1 - (step + 1) / 3);
		el.fill.style.strokeDashoffset = Math.max(0, offset);
	}

	function advanceStep() {
		if (progressStep < 2) {
			progressStep++;
			activateStep(progressStep);
		}
	}

	function startProgressTimer() {
		showProgressRing();
		// step 0 immediately, then every 15 s
		advanceStep();
		progressTimer = setInterval(advanceStep, 15000);
	}

	function setFormBusy(isBusy) {
		var fields = ["email", "full_name", "company_slug", "password"];
		fields.forEach(function (id) {
			var el = byId(id);
			if (el) el.disabled = !!isBusy;
		});

		var continueBtn = byId("continue-btn");
		continueBtn.disabled = !!isBusy;

		var createBtn = byId("create-btn");
		createBtn.disabled = !!isBusy;
		createBtn.classList.toggle("loading", !!isBusy);
		createBtn.textContent = isBusy ? "Creating Tenant..." : "Create Tenant";
	}

	function toggleSignup(show) {
		byId("signup-fields").classList.toggle("hidden", !show);
		byId("create-btn").classList.toggle("hidden", !show);
	}

	async function callApi(methodPath, payload) {
		var headers = { "Content-Type": "application/json" };
		if (window.csrf_token) {
			headers["X-Frappe-CSRF-Token"] = window.csrf_token;
		}

		var response = await fetch("/api/method/" + methodPath, {
			method: "POST",
			headers: headers,
			body: JSON.stringify(payload),
		});

		var data = await response.json();
		if (!response.ok || data.exc) {
			throw new Error((data && data._server_messages) || "API request failed");
		}

		return data.message || {};
	}

	async function handleContinue() {
		setNotice("");
		toggleSignup(false);

		var email = byId("email").value.trim();
		if (!email) {
			setNotice("Enter your email to continue.", true);
			return;
		}

		byId("continue-btn").disabled = true;
		try {
			var result = await callApi("saas_control.saas_control.api.resolve_tenant", {
				email: email,
			});
			if (result.found && result.redirect_url) {
				setNotice("Tenant found. Redirecting to login...");
				window.location.href = result.redirect_url;
				return;
			}

			setNotice("No active tenant found. Complete signup fields to create a new tenant.");
			toggleSignup(true);
		} catch (error) {
			setNotice("Unable to resolve tenant right now.", true);
		} finally {
			byId("continue-btn").disabled = false;
		}
	}

	async function handleCreateTenant() {
		setNotice("");

		var email = byId("email").value.trim();
		var fullName = byId("full_name").value.trim();
		var companySlug = byId("company_slug").value.trim();
		var password = byId("password").value;

		if (!email || !fullName || !companySlug || !password) {
			setNotice("Fill in all signup fields.", true);
			return;
		}

		setFormBusy(true);
		startProgressTimer();
		setNotice("Creating tenant. This usually takes 1–2 minutes.", false);
		try {
			var result = await callApi("saas_control.saas_control.api.create_or_login", {
				email: email,
				full_name: fullName,
				company_slug: companySlug,
				password: password,
			});

			if (result.redirect_url) {
				setNotice("Tenant ready. Redirecting to login...");
				hideProgressRing();
				window.location.href = result.redirect_url;
				return;
			}

			setNotice("Tenant created but redirect URL missing.", true);
		} catch (error) {
			setNotice("Tenant creation failed. Try a different company slug.", true);
		} finally {
			setFormBusy(false);
			hideProgressRing();
		}
	}

	function wireEvents() {
		byId("continue-btn").addEventListener("click", function (event) {
			event.preventDefault();
			handleContinue();
		});

		byId("create-btn").addEventListener("click", function (event) {
			event.preventDefault();
			handleCreateTenant();
		});
	}

	document.addEventListener("DOMContentLoaded", wireEvents);
})();
